#!/usr/bin/env bash
# Задание 5. Развёртывание четырёх сервисов, применение сетевых политик и проверка трафика.
#
# Сетевые политики работают только с CNI, который их поддерживает (Calico, Cilium).
# Стандартная сеть minikube политики принимает, но не применяет — весь трафик будет разрешён.
#
# Запуск: ./deploy-and-check.sh
#         CONTEXT=<контекст> NAMESPACE=<namespace> ./deploy-and-check.sh

set -euo pipefail
cd "$(dirname "$0")"

CONTEXT="${CONTEXT:-minikube}"
NAMESPACE="${NAMESPACE:-default}"
ROLES=(front-end back-end-api admin-front-end admin-back-end-api)

kc() { kubectl --context "$CONTEXT" -n "$NAMESPACE" "$@"; }

echo "==> Сервисы"
for role in "${ROLES[@]}"; do
  if kc get pod "$role-app" >/dev/null 2>&1; then
    echo "    $role-app уже существует"
  else
    kc run "$role-app" --image=nginx --labels "role=$role" --expose --port 80 >/dev/null
    echo "    $role-app создан (метка role=$role)"
  fi
done
kc wait --for=condition=Ready pod "${ROLES[@]/%/-app}" --timeout=180s >/dev/null

echo "==> Сетевые политики"
kc apply -f non-admin-api-allow.yaml

# ---------------------------------------------------------------- проверка
pass=0; fail=0
check() {   # источник(роль или "unlabeled") цель(роль) ожидание(yes|no)
  local from="$1" to="$2" expected="$3" actual cmd
  if [[ "$from" == unlabeled ]]; then
    # Под без метки, как в условии задания: kubectl run test-$RANDOM --image=alpine
    cmd=(kubectl --context "$CONTEXT" -n "$NAMESPACE" run "test-$RANDOM" --rm -i --restart=Never --image=alpine --quiet --
         wget -qO- --timeout=2 "http://$to-app")
  else
    cmd=(kubectl --context "$CONTEXT" -n "$NAMESPACE" exec "$from-app" -- curl -sf -m 2 -o /dev/null "http://$to-app")
  fi
  if "${cmd[@]}" >/dev/null 2>&1; then actual=yes; else actual=no; fi
  if [[ "$actual" == "$expected" ]]; then
    pass=$((pass + 1)); printf '  OK    %-20s -> %-20s %s\n' "$from" "$to" "$actual"
  else
    fail=$((fail + 1)); printf '  FAIL  %-20s -> %-20s %s (ожидалось %s)\n' "$from" "$to" "$actual" "$expected"
  fi
  printf '        $ %s\n' "${cmd[*]}"
}

echo "==> Проверка трафика (источник -> цель: доступ)"
for from in "${ROLES[@]}"; do
  for to in "${ROLES[@]}"; do
    [[ "$from" == "$to" ]] && continue
    case "$from:$to" in
      front-end:back-end-api|back-end-api:front-end|admin-front-end:admin-back-end-api|admin-back-end-api:admin-front-end)
        check "$from" "$to" yes ;;
      *)
        check "$from" "$to" no ;;
    esac
  done
done
for to in "${ROLES[@]}"; do
  check unlabeled "$to" no
done

echo "==> Итог: $pass проверок пройдено, $fail не пройдено"
[[ "$fail" -eq 0 ]]
