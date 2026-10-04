#!/usr/bin/env bash
# Задание 7. Проверка Pod Security Admission в namespace audit-zone.
#
#   1. Создаёт namespace audit-zone с уровнем restricted (01-create-namespace.yaml).
#   2. Проверяет, что PodSecurity включён: метки на namespace и отказ API-сервера.
#   3. Применяет insecure-manifests/ — каждый под должен быть отклонён PodSecurity.
#   4. Применяет secure-manifests/ — каждый под должен быть принят и запуститься.
#
# Если Gatekeeper уже установлен, небезопасные поды всё равно отклоняет PodSecurity:
# встроенный плагин работает раньше вебхуков. Gatekeeper проверяет validate-security.sh.
#
# Запуск: ./verify/verify-admission.sh
#         CONTEXT=<контекст> ./verify/verify-admission.sh

set -euo pipefail
cd "$(dirname "$0")/.."

CONTEXT="${CONTEXT:-minikube}"
NAMESPACE=audit-zone

kc() { kubectl --context "$CONTEXT" "$@"; }

pass=0; fail=0
result() {   # ok(0|1) описание
  if [[ "$1" -eq 0 ]]; then
    pass=$((pass + 1)); printf '  OK    %s\n' "$2"
  else
    fail=$((fail + 1)); printf '  FAIL  %s\n' "$2"
  fi
}

echo "==> Namespace $NAMESPACE"
kc apply -f 01-create-namespace.yaml
enforce=$(kc get ns "$NAMESPACE" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}')
[[ "$enforce" == restricted ]] && ok=0 || ok=1
result "$ok" "метка pod-security.kubernetes.io/enforce=$enforce"

echo "==> Небезопасные манифесты: ожидается отказ PodSecurity"
for f in insecure-manifests/*.yaml; do
  cmd=(kubectl --context "$CONTEXT" apply -f "$f")
  if out=$("${cmd[@]}" 2>&1); then rc=0; else rc=1; fi
  [[ "$rc" -ne 0 && "$out" == *'violates PodSecurity "restricted'* ]] && ok=0 || ok=1
  result "$ok" "$f отклонён"
  printf '        $ %s\n' "${cmd[*]}"
  grep -o 'violates PodSecurity.*' <<<"$out" | sed 's/^/        /' || printf '        %s\n' "$out"
done

echo "==> Безопасные манифесты: ожидается приём и запуск"
for f in secure-manifests/*.yaml; do
  cmd=(kubectl --context "$CONTEXT" apply -f "$f")
  pod=$(kc apply -f "$f" --dry-run=client -o jsonpath='{.metadata.name}')
  if out=$("${cmd[@]}" 2>&1); then rc=0; else rc=1; fi
  if [[ "$rc" -eq 0 ]] && kc -n "$NAMESPACE" wait --for=condition=Ready "pod/$pod" --timeout=120s >/dev/null 2>&1; then
    result 0 "$f принят, под $pod запущен"
  else
    result 1 "$f: под $pod не принят или не запустился"
    printf '        %s\n' "$out"
  fi
  printf '        $ %s\n' "${cmd[*]}"
done

echo "==> Итог: $pass проверок пройдено, $fail не пройдено"
[[ "$fail" -eq 0 ]]
