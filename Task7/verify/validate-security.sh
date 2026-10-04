#!/usr/bin/env bash
# Задание 7. Применение правил OPA Gatekeeper и проверка, что Gatekeeper их соблюдает.
#
#   1. Проверяет, что Gatekeeper установлен и его вебхук зарегистрирован.
#   2. Применяет шаблоны и ограничения из gatekeeper/ и ждёт, пока они вступят в силу.
#   3. Проверяет небезопасные и безопасные манифесты через --dry-run=server: запрос проходит
#      весь admission, включая вебхуки, но объект не создаётся.
#
# PodSecurity срабатывает раньше Gatekeeper, поэтому на время проверки уровень enforce
# для audit-zone снижается до privileged: отказ тогда может прийти только от Gatekeeper.
# После проверки (в том числе при ошибке) уровень restricted возвращается.
#
# Сначала нужен namespace audit-zone: ./verify/verify-admission.sh
#
# Запуск: ./verify/validate-security.sh
#         CONTEXT=<контекст> ./verify/validate-security.sh

set -euo pipefail
cd "$(dirname "$0")/.."

CONTEXT="${CONTEXT:-minikube}"
NAMESPACE=audit-zone
PSA_LABEL=pod-security.kubernetes.io/enforce
GATEKEEPER_VERSION=v3.23.1

kc() { kubectl --context "$CONTEXT" "$@"; }

pass=0; fail=0
result() {   # ok(0|1) описание
  if [[ "$1" -eq 0 ]]; then
    pass=$((pass + 1)); printf '  OK    %s\n' "$2"
  else
    fail=$((fail + 1)); printf '  FAIL  %s\n' "$2"
  fi
}

echo "==> Gatekeeper"
if ! kc get ns gatekeeper-system >/dev/null 2>&1; then
  echo "Gatekeeper не установлен. Установка:"
  echo "  kubectl apply -f https://raw.githubusercontent.com/open-policy-agent/gatekeeper/$GATEKEEPER_VERSION/deploy/gatekeeper.yaml"
  exit 1
fi
kc -n gatekeeper-system wait --for=condition=Available deploy --all --timeout=180s >/dev/null 2>&1 && ok=0 || ok=1
result "$ok" "поды gatekeeper-system готовы"
kc get validatingwebhookconfiguration gatekeeper-validating-webhook-configuration >/dev/null 2>&1 && ok=0 || ok=1
result "$ok" "вебхук validation.gatekeeper.sh зарегистрирован"

echo "==> Шаблоны и ограничения"
kc apply -f gatekeeper/constraint-templates/
for f in gatekeeper/constraint-templates/*.yaml; do
  name=$(kc apply -f "$f" --dry-run=client -o jsonpath='{.metadata.name}')
  kc wait --for=jsonpath='{.status.created}'=true "constrainttemplate/$name" --timeout=60s >/dev/null
done
kc apply -f gatekeeper/constraints/
for f in gatekeeper/constraints/*.yaml; do
  ref=$(kc apply -f "$f" --dry-run=client -o jsonpath='{.kind}/{.metadata.name}')
  # status.byPod заполняется, когда ограничение загружено во все поды Gatekeeper
  for _ in $(seq 30); do
    enforced=$(kc get "$ref" -o jsonpath='{.status.byPod[*].enforced}')
    [[ -n "$enforced" && "$enforced" != *false* ]] && break
    sleep 2
  done
  action=$(kc get "$ref" -o jsonpath='{.spec.enforcementAction}')
  [[ -n "$enforced" && "$enforced" != *false* && "$action" == deny ]] && ok=0 || ok=1
  result "$ok" "$ref: enforced, enforcementAction=$action"
done

echo "==> PodSecurity для $NAMESPACE временно снижен до privileged"
trap 'kc label ns "$NAMESPACE" "$PSA_LABEL=restricted" --overwrite >/dev/null; echo "==> PodSecurity для $NAMESPACE снова restricted"' EXIT
kc label ns "$NAMESPACE" "$PSA_LABEL=privileged" --overwrite >/dev/null

echo "==> Небезопасные манифесты: ожидается отказ Gatekeeper"
for f in insecure-manifests/*.yaml; do
  cmd=(kubectl --context "$CONTEXT" apply --dry-run=server -f "$f")
  if out=$("${cmd[@]}" 2>&1); then rc=0; else rc=1; fi
  [[ "$rc" -ne 0 && "$out" == *'admission webhook "validation.gatekeeper.sh" denied'* ]] && ok=0 || ok=1
  result "$ok" "$f отклонён"
  printf '        $ %s\n' "${cmd[*]}"
  grep -o '\[[a-z-]*\] .*' <<<"$out" | sed 's/^/        /' || printf '        %s\n' "$out"
done

echo "==> Безопасные манифесты: ожидается приём"
for f in secure-manifests/*.yaml; do
  cmd=(kubectl --context "$CONTEXT" apply --dry-run=server -f "$f")
  if out=$("${cmd[@]}" 2>&1); then rc=0; else rc=1; fi
  result "$rc" "$f принят"
  [[ "$rc" -eq 0 ]] || printf '        %s\n' "$out"
  printf '        $ %s\n' "${cmd[*]}"
done

echo "==> Итог: $pass проверок пройдено, $fail не пройдено"
[[ "$fail" -eq 0 ]]
