# Задание 7. Pod Security Admission и OPA Gatekeeper

Окружение: Minikube v1.39.0, Kubernetes v1.37.0, Calico, OPA Gatekeeper v3.23.1.

Требования к подам проверяются двумя независимыми механизмами:

| Механизм | Где задан | Что проверяет |
| --- | --- | --- |
| Pod Security Admission | Метки namespace `audit-zone` (`01-create-namespace.yaml`) | Уровень `restricted`: без privileged, hostPath, root; обязательны `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, `seccompProfile` |
| OPA Gatekeeper | `gatekeeper/` | Правила задания: без `privileged: true` и `hostPath`; `runAsNonRoot: true`; `readOnlyRootFilesystem: true` |

Pod Security встроен в API-сервер и включён по умолчанию, но не требует `readOnlyRootFilesystem`. Gatekeeper добавляет это требование и позволяет описывать собственные правила.

## Запуск

```bash
cd Task7

# 1. Namespace, небезопасные и безопасные манифесты, проверка Pod Security
./verify/verify-admission.sh

# 2. Установка Gatekeeper
kubectl apply -f https://raw.githubusercontent.com/open-policy-agent/gatekeeper/v3.23.1/deploy/gatekeeper.yaml

# 3. Шаблоны и ограничения Gatekeeper, проверка Gatekeeper
./verify/validate-security.sh
```

Скрипты используют контекст `minikube`, другой задаётся переменной `CONTEXT`. Каждая проверка печатает результат (`OK` / `FAIL`) и команду, которой она выполнена. В конце выводится итог.

Удаление: `kubectl delete ns audit-zone`, `kubectl delete -f gatekeeper/constraints/ -f gatekeeper/constraint-templates/`.

## Файлы

| Файл | Назначение |
| --- | --- |
| `01-create-namespace.yaml` | Namespace `audit-zone` с метками `enforce`, `audit`, `warn` уровня `restricted` |
| `insecure-manifests/01-privileged-pod.yaml` | `privileged: true` |
| `insecure-manifests/02-hostpath-pod.yaml` | Том `hostPath` с корнем узла `/` |
| `insecure-manifests/03-root-user-pod.yaml` | `runAsUser: 0` |
| `secure-manifests/01..03-secure.yaml` | Исправленные версии, проходят и Pod Security, и Gatekeeper |
| `gatekeeper/constraint-templates/` | Правила на Rego (ConstraintTemplate) |
| `gatekeeper/constraints/` | Применение правил к подам в `audit-zone`, `enforcementAction: deny` |
| `verify/verify-admission.sh` | Проверка Pod Security |
| `verify/validate-security.sh` | Применение и проверка правил Gatekeeper |
| `audit-policy.yaml` | Политика аудита попыток развернуть поды и изменений механизмов контроля |

## Исправления манифестов

Все три безопасных манифеста построены одинаково, отличаются только исправленным нарушением:

| Нарушение | Исправление |
| --- | --- |
| `privileged: true` | Убрано, `capabilities.drop: [ALL]`, `allowPrivilegeEscalation: false` |
| `hostPath: /` | Том `emptyDir`. Если данные должны пережить под — PersistentVolumeClaim |
| `runAsUser: 0` | `runAsUser: 101`, `runAsNonRoot: true` |

Общие изменения:
- **Образ.** Вместо `nginx` используется `nginxinc/nginx-unprivileged:1.31-alpine`. Обычный `nginx` запускает мастер-процесс от root и слушает порт 80, поэтому с `runAsNonRoot` он не стартует. Образ `nginx-unprivileged` работает от UID 101 и слушает порт 8080.
- **Корневая файловая система только для чтения.** nginx пишет PID и временные файлы в `/tmp`, поэтому туда смонтирован `emptyDir`.
- **`seccompProfile: RuntimeDefault`.** Обязателен для уровня `restricted`.

Поды не просто проходят admission, а запускаются: `verify-admission.sh` ждёт их готовности.

## Правила Gatekeeper

| Шаблон | Kind | Ограничение | Проверка |
| --- | --- | --- | --- |
| `privileged.yaml` | `K8sDenyPrivileged` | `deny-privileged` | `securityContext.privileged: true` |
| `hostpath.yaml` | `K8sDenyHostPath` | `deny-hostpath` | Тома `hostPath` |
| `runasnonroot.yaml` | `K8sRunAsNonRoot` | `require-run-as-non-root` | `runAsNonRoot: true`, `runAsUser` не 0, `readOnlyRootFilesystem: true` |

Особенности:
- **Четыре правила в трёх шаблонах.** Структура задания отводит три файла, поэтому `readOnlyRootFilesystem` проверяется в `runasnonroot.yaml` вместе с пользователем.
- **Контейнеры.** Проверяются обычные, init- и ephemeral-контейнеры. `runAsNonRoot` и `runAsUser` берутся из контейнера, а если там не заданы — из `securityContext` пода, как это делает Kubernetes.
- **`runAsUser: 0` проверяется отдельно.** `runAsNonRoot: true` вместе с явным `runAsUser: 0` API-сервер принимает, а под не запустится только на узле. Gatekeeper отклоняет такой манифест сразу.
- **Область — только `audit-zone`.** Calico и kube-proxy работают привилегированно, ограничение на весь кластер не дало бы им перезапуститься.

Правила проверены локально в OPA на всех шести манифестах: небезопасные дают нарушения своего правила, безопасные — ни одного.

## Порядок срабатывания и проверка Gatekeeper

Pod Security — встроенный admission-плагин, он работает раньше вебхуков. Поэтому в `audit-zone` небезопасный под отклоняет Pod Security, и до Gatekeeper запрос не доходит.

Чтобы доказать, что Gatekeeper работает самостоятельно, `validate-security.sh`:
1. временно снижает `pod-security.kubernetes.io/enforce` для `audit-zone` до `privileged` (метки `audit` и `warn` остаются `restricted`);
2. отправляет манифесты с `--dry-run=server`: запрос проходит весь admission, включая вебхуки, но объект не создаётся;
3. проверяет, что отказ пришёл от `validation.gatekeeper.sh`;
4. возвращает `restricted`, в том числе при ошибке скрипта.

Так видно, что механизмы дублируют друг друга: отключение одного не открывает дорогу небезопасным подам.

## Аудит

`audit-policy.yaml` записывает:
- **Попытки создать или изменить поды в `audit-zone`.** Пишется тело запроса, в том числе для отклонённых запросов. Отказ Pod Security виден по коду 403 и аннотации `pod-security.kubernetes.io/enforce-policy`, отказ Gatekeeper — по сообщению `admission webhook "validation.gatekeeper.sh" denied`.
- **Изменения namespace.** Снятие меток `pod-security.kubernetes.io/*` отключает Pod Security.
- **Изменения шаблонов, ограничений и конфигурации Gatekeeper.**
- **Изменения конфигурации вебхуков.** Удаление вебхука Gatekeeper отключает все его правила.
- **Secrets — только на уровне Metadata.** Как показало задание 6, иначе содержимое секретов попадает в журнал.

Политика подключается так же, как в задании 6 (`Task6/01-start-minikube-audit.sh`).

Gatekeeper ведёт и собственный аудит. Он периодически проверяет уже существующие объекты и записывает нарушения в `status.violations` ограничений: `kubectl get k8sdenyprivileged deny-privileged -o yaml`.
