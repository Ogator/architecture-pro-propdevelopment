# Задание 4. Ролевая модель доступа к Kubernetes

## Принципы

- **Права выдаются группам, а не людям.** Группы повторяют оргструктуру компании: домен → продуктовая команда → роль в команде (`propdev:<домен>:<роль>`). Человек получает права, когда его добавляют в группу.
- **Пространства имён по доменам.** Каждый домен работает в своём namespace, команда домена не видит чужие:

  | Namespace | Домен / команда                                                           | Классификация данных |
  | --- |---------------------------------------------------------------------------| --- |
  | `sales` | Группа сервисов для продаж: витрина, client-mart, client-tour, client-crm | Секретные (данные онлайн-сделки) |
  | `housing` | Группа сервисов ЖКУ: tenant-core, CRM собственников, сервисы «Умный дом» (smart-access-service, notification-service) | Конфиденциальные |
  | `finance` | Финансы: accountant-service                                               | Секретные |
  | `data` | Дата: загрузка в DWH, BI, отчётность                                      | Секретные (сырые копии всех БД) |

- **Просмотр секретов — привилегированное действие.** Секреты читают только специалист по ИБ (во всём кластере) и администраторы домена (только в своём namespace).
- **Разделение обязанностей.** Тот, кто настраивает кластер, не читает секреты и не раздаёт права. Тот, кто раздаёт права, не разворачивает приложения.
- **Журналы подов недоступны ролям просмотра:** в логах могут оказаться персональные данные.
- **Платформенная команда не управляет приложениями доменов.** Она настраивает ресурсы уровня кластера и системные компоненты в платформенных namespace (`ingress-nginx`, `kubernetes-dashboard`, `monitoring`, `logging`, `tracing`, `cert-manager`). Приложения в namespace доменов меняют только команды доменов.
- **`kube-system` не изменяет никто, кроме аварийной группы.** Под с привилегированным сервисным аккаунтом в `kube-system` фактически даёт права администратора кластера, поэтому компоненты ядра меняются только через GitOps или break-glass.

## Роли

| Роль | Права роли | Группы пользователей |
| --- | --- | --- |
| `propdev-cluster-viewer` | **Только просмотр, весь кластер.** `get`, `list`, `watch` для namespaces, nodes, pods, services, workloads (deployments, statefulsets, daemonsets, jobs, cronjobs), ingresses, networkpolicies, PV/PVC, events, quotas, storage classes, метрик. **Нельзя:** secrets, configmaps, журналы подов (`pods/log`), `exec`, любые изменения | `propdev:cluster-viewers` — архитекторы, бизнес-аналитики, которые администрируют системы, аудиторы |
| `propdev-cluster-operator` | **Настройка кластера, только ресурсы уровня кластера.** Создание и удаление namespaces. Управление nodes (cordon, drain через `pods/eviction`), PV, storage classes, CSI, CRD, priority classes, ingress classes. Квоты и limit ranges во всех namespace (распределение ресурсов между доменами). RBAC — только просмотр. Дополнительно получает `propdev-cluster-viewer` для диагностики. **Нельзя:** менять workloads, services, configmaps и ingress в namespace доменов, читать secrets и `pods/log`, `exec`/`port-forward`, изменять RBAC и network policies, менять метки namespace (Pod Security) | `propdev:platform:operators` — DevOps-инженеры платформенной команды |
| `propdev-platform-component` | **Системные компоненты в платформенных namespace:** `ingress-nginx` (входящий трафик), `kubernetes-dashboard` (веб-консоль), `monitoring` (Prometheus, Alertmanager, Grafana), `logging` (сбор и хранение логов: Fluent Bit, Loki или OpenSearch), `tracing` (Tempo или Jaeger), `cert-manager` (выпуск TLS-сертификатов). Права: deployments, **daemonsets**, statefulsets, jobs, services, configmaps, **сервисные аккаунты**, HPA, PDB, перезапуск подов, `pods/log`. **Нельзя:** secrets, `exec`/`port-forward`, изменять network policies и RBAC, работать в namespace доменов и `kube-system` | `propdev:platform:operators` — DevOps-инженеры платформенной команды |
| `propdev-security-admin` *(привилегированная)* | **Секреты и права доступа, весь кластер.** Полный доступ к secrets. Создание и изменение RoleBinding и ClusterRoleBinding, но только для ролей `propdev-*` (`bind` по `resourceNames`), без возможности выдать `cluster-admin`. Управление network policies, admission webhooks и политиками, метками Pod Security на namespaces. Дополнительно получает `propdev-cluster-viewer`. **Нельзя:** разворачивать и менять приложения, `exec`, изменять сами роли | `propdev:security:admins` — специалист по ИБ |
| `propdev-ns-admin` *(привилегированная, в пределах namespace)* | **Полный доступ к своему namespace:** workloads, services, configmaps, ingress, network policies, **secrets**, `exec`, `port-forward`, сервисные аккаунты. **Нельзя:** изменять RBAC, работать в чужих namespace и с ресурсами уровня кластера | `propdev:<домен>:admins` — DevOps-инженеры и ведущие инженеры эксплуатации команды домена |
| `propdev-ns-developer` | **Разработка в своём namespace:** создание и изменение deployments, statefulsets, jobs, cronjobs, services, configmaps, ingress, HPA, PDB. Просмотр и перезапуск (`delete`) подов, чтение `pods/log`. **Нельзя:** secrets (секреты подкладывают администраторы домена или Vault), `exec`, `port-forward`, network policies, RBAC | `propdev:<домен>:developers` — разработчики продуктовых команд |
| `propdev-ns-viewer` | **Просмотр своего namespace:** pods, workloads, services, ingress, events, quotas, метрики. **Нельзя:** secrets, configmaps, `pods/log`, любые изменения | `propdev:<домен>:viewers` — владельцы продуктов, бизнес-аналитики команды, менеджеры операционной команды |
| `cluster-admin` *(встроенная, аварийная)* | Полный доступ ко всему кластеру | `propdev:breakglass` — постоянных участников нет. Доступ выдаётся временно при инциденте по согласованию со специалистом по ИБ, с коротким сроком действия и разбором после |

`propdev-cluster-viewer`, `propdev-cluster-operator` и `propdev-security-admin` — ClusterRole, назначаются через ClusterRoleBinding на весь кластер. `propdev-platform-component` и `propdev-ns-*` — Role, создаются в каждом нужном namespace и назначаются через RoleBinding в нём же.

У платформенной команды две роли, потому что её права делятся по области действия, а не по людям. Ресурсы уровня кластера (nodes, namespaces, storage classes, CRD) выдаются только через ClusterRoleBinding, а он открыл бы workloads во всех namespace, включая доменные. Поэтому workloads вынесены в Role `propdev-platform-component`, которая есть только в платформенных namespace.

## Группы по namespace

| Группа | Namespace | Роль |
| --- | --- | --- |
| `propdev:platform:operators` | `ingress-nginx`, `kubernetes-dashboard`, `monitoring`, `logging`, `tracing`, `cert-manager` | `propdev-platform-component` |
| `propdev:sales:admins` / `:developers` / `:viewers` | `sales` | `propdev-ns-admin` / `-developer` / `-viewer` |
| `propdev:housing:admins` / `:developers` / `:viewers` | `housing` | то же |
| `propdev:finance:admins` / `:developers` / `:viewers` | `finance` | то же |
| `propdev:data:admins` / `:developers` / `:viewers` | `data` | то же |

## Тестовые пользователи

Для проверки модели создаются пользователи, покрывающие все типы ролей:

| Пользователь | Группа | Что должен уметь | Чего не должен уметь |
| --- | --- | --- | --- |
| `analyst-viewer` | `propdev:cluster-viewers` | Смотреть поды во всех namespace | Читать secrets, логи, что-либо менять |
| `platform-devops` | `propdev:platform:operators` | Создавать namespace и квоты, управлять узлами и storage classes, разворачивать компоненты в `ingress-nginx` | Менять приложения в `finance` и других namespace доменов, читать их логи, менять `kube-system`, читать secrets, менять RBAC |
| `security-officer` | `propdev:security:admins` | Читать secrets в любом namespace, выдавать роли `propdev-*` | Разворачивать приложения, выдать `cluster-admin`, изменить роли |
| `sales-developer` | `propdev:sales:developers` | Разворачивать приложения в `sales` | Читать secrets, работать в `finance` и других namespace |
| `sales-devops` | `propdev:sales:admins` | Читать secrets и выполнять `exec` в `sales` | Читать secrets в `finance` |
| `housing-po` | `propdev:housing:viewers` | Смотреть поды в `housing` | Читать configmaps, смотреть `sales` |
| `housing-developer` | `propdev:housing:developers` | Разворачивать приложения в `housing`, включая сервисы «Умный дом» | Читать secrets, работать в `sales` |

## Ограничения и замечания

- **Пользователи в Minikube — клиентские сертификаты.** Группы записаны в поле O сертификата. Отозвать сертификат в Kubernetes нельзя, поэтому срок его действия короткий (7 суток). В продуктиве пользователи приходят через OIDC из Keycloak, федерированного с Active Directory. Группы берутся из claim `groups`, и увольнение или перевод сотрудника сразу снимает права (единый реестр учётных записей — проблема из задания 2).
- **Косвенный доступ к секретам.** Тот, кто может создать под в namespace, может смонтировать в него существующий секрет. Это касается `propdev-ns-developer` и `propdev-platform-component`. Для платформы риск выше: в платформенных namespace нет ограничений Pod Security, а у сервисных аккаунтов системных компонентов широкие права (например, ingress-nginx читает secrets во всём кластере). Под, запущенный от такого аккаунта, получает эти права. Закрывается политиками admission (Kyverno или ValidatingAdmissionPolicy, например запрет произвольного `serviceAccountName`), изменением платформенных namespace только через GitOps, доставкой секретов из Vault и аудитом.
- **Аудит.** Действия привилегированных ролей и `cluster-admin` фиксируются в audit log API-сервера и отправляются в SIEM (задание 2, раздел IV).
