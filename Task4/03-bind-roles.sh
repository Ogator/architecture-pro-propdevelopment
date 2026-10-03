#!/usr/bin/env bash
# Задание 4, шаг 5. Привязка пользователей к ролям.
#
# Роли привязываются к группам из оргструктуры, а не к отдельным людям: пользователь получает
# права через группы, записанные в его сертификате (01-create-users.sh).
#   - роли уровня кластера  — ClusterRoleBinding на ClusterRole;
#   - роли namespace        — RoleBinding на Role из того же namespace (права только в нём).
#
# После привязки скрипт проверяет права каждого тестового пользователя из его собственного
# контекста (kubectl auth can-i) и сверяет с ожидаемым результатом из roles.md.
#
# Запуск: ./03-bind-roles.sh            — привязка и проверка
#         ./03-bind-roles.sh --no-verify — только привязка

set -euo pipefail
source "$(dirname "$0")/common.sh"

cluster_binding() {   # имя роль группа
  kc apply -f - >/dev/null <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: $1
  labels:
    propdev.ru/managed-by: task4-rbac
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: $2
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: Group
    name: $3
EOF
  echo "    ClusterRoleBinding $1: $3 -> $2"
}

namespace_binding() {   # namespace роль группа
  kc apply -f - >/dev/null <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: $2
  namespace: $1
  labels:
    propdev.ru/managed-by: task4-rbac
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: $2
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: Group
    name: $3
EOF
  echo "    RoleBinding $1/$2: $3 -> $2"
}

echo "==> Роли уровня кластера"
cluster_binding propdev-cluster-viewers   propdev-cluster-viewer   propdev:cluster-viewers
cluster_binding propdev-platform-operators propdev-cluster-operator propdev:platform:operators
cluster_binding propdev-platform-viewers  propdev-cluster-viewer   propdev:platform:operators
cluster_binding propdev-security-admins   propdev-security-admin   propdev:security:admins
cluster_binding propdev-security-viewers  propdev-cluster-viewer   propdev:security:admins
cluster_binding propdev-breakglass        cluster-admin            propdev:breakglass

echo "==> Системные компоненты платформы"
for ns in $(existing_platform_namespaces); do
  namespace_binding "$ns" propdev-platform-component propdev:platform:operators
done

echo "==> Роли доменов"
for ns in "${DOMAINS[@]}"; do
  namespace_binding "$ns" propdev-ns-admin     "propdev:$ns:admins"
  namespace_binding "$ns" propdev-ns-developer "propdev:$ns:developers"
  namespace_binding "$ns" propdev-ns-viewer    "propdev:$ns:viewers"
done

[[ "${1:-}" == "--no-verify" ]] && exit 0

# ---------------------------------------------------------------- проверка
CLUSTER="$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"$ADMIN_CONTEXT\")].context.cluster}")"
pass=0; fail=0
check() {   # пользователь ожидание(yes|no) аргументы auth can-i...
  local user="$1" expected="$2"; shift 2
  local actual
  actual="$(kubectl --context "$user@$CLUSTER" auth can-i "$@" 2>/dev/null || true)"
  if [[ "$actual" == "$expected" ]]; then
    pass=$((pass + 1)); printf '  OK    %-18s can-i %-45s -> %s\n' "$user" "$*" "$actual"
  else
    fail=$((fail + 1)); printf '  FAIL  %-18s can-i %-45s -> %s (ожидалось %s)\n' "$user" "$*" "$actual" "$expected"
  fi
}

echo "==> Проверка прав пользователей"
check analyst-viewer    yes list pods -A
check analyst-viewer    yes list nodes
check analyst-viewer    no  get secrets -n sales
check analyst-viewer    no  get configmaps -n housing
check analyst-viewer    no  get pods --subresource=log -n sales
check analyst-viewer    no  create deployments -n sales

check platform-devops   yes create namespaces
check platform-devops   yes patch nodes
check platform-devops   yes create pods --subresource=eviction -n sales
check platform-devops   yes create resourcequotas -n sales
check platform-devops   yes create storageclasses
check platform-devops   yes list pods -A
check platform-devops   yes create deployments -n ingress-nginx
check platform-devops   yes create daemonsets -n ingress-nginx
check platform-devops   no  create deployments -n finance
check platform-devops   no  get configmaps -n sales
check platform-devops   no  get pods --subresource=log -n sales
check platform-devops   no  create deployments -n kube-system
check platform-devops   no  get secrets -n ingress-nginx
check platform-devops   no  get secrets -n finance
check platform-devops   no  create pods --subresource=exec -n ingress-nginx
check platform-devops   no  create clusterrolebindings
check platform-devops   no  patch namespaces

check security-officer  yes get secrets -n finance
check security-officer  yes list secrets -A
check security-officer  yes create rolebindings -n sales
check security-officer  yes list pods -A
check security-officer  no  create deployments -n sales
check security-officer  no  create pods --subresource=exec -n sales
check security-officer  no  bind clusterroles/cluster-admin
check security-officer  yes bind roles/propdev-ns-admin -n sales
check security-officer  no  update roles/propdev-ns-admin -n sales

check sales-developer   yes create deployments -n sales
check sales-developer   yes get pods --subresource=log -n sales
check sales-developer   no  get secrets -n sales
check sales-developer   no  create pods --subresource=exec -n sales
check sales-developer   no  create deployments -n finance
check sales-developer   no  list pods -n housing

check sales-devops      yes get secrets -n sales
check sales-devops      yes create pods --subresource=exec -n sales
check sales-devops      no  get secrets -n finance
check sales-devops      no  create rolebindings -n sales

check housing-po        yes list pods -n housing
check housing-po        no  get configmaps -n housing
check housing-po        no  get pods --subresource=log -n housing
check housing-po        no  list pods -n sales

check housing-developer yes create deployments -n housing
check housing-developer no  get secrets -n housing
check housing-developer no  create deployments -n sales

echo "==> Итог: $pass проверок пройдено, $fail не пройдено"
[[ "$fail" -eq 0 ]]
