#!/usr/bin/env bash
# Задание 4, шаг 3. Создание пользователей Kubernetes.
#
# Пользователь — клиентский сертификат, подписанный CA кластера через CertificateSigningRequest API.
# CN сертификата — имя пользователя, O — группы (propdev:<домен>:<роль>), к которым
# привязываются роли в 03-bind-roles.sh.
#
# Для каждого пользователя в kubeconfig создаются credentials и контекст <user>@<cluster>.
# Текущий контекст не меняется. Закрытые ключи сохраняются в ./users (исключены из git).
#
# Запуск: ./01-create-users.sh   (нужен kubectl с правами администратора кластера)

set -euo pipefail

ADMIN_CONTEXT="${ADMIN_CONTEXT:-minikube}"
CERT_DIR="${CERT_DIR:-$(cd "$(dirname "$0")" && pwd)/users}"
CERT_TTL_SECONDS="${CERT_TTL_SECONDS:-604800}"   # 7 суток: сертификат нельзя отозвать, поэтому срок короткий

# пользователь|группы через запятую
USERS=(
  "analyst-viewer|propdev:cluster-viewers"
  "platform-devops|propdev:platform:operators"
  "security-officer|propdev:security:admins"
  "sales-developer|propdev:sales:developers"
  "sales-devops|propdev:sales:admins"
  "housing-po|propdev:housing:viewers"
  "housing-developer|propdev:housing:developers"
)

kc() { kubectl --context "$ADMIN_CONTEXT" "$@"; }

CLUSTER="$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"$ADMIN_CONTEXT\")].context.cluster}")"
[[ -n "$CLUSTER" ]] || { echo "Контекст $ADMIN_CONTEXT не найден в kubeconfig" >&2; exit 1; }

mkdir -p "$CERT_DIR"
chmod 700 "$CERT_DIR"

for entry in "${USERS[@]}"; do
  user="${entry%%|*}"
  groups="${entry#*|}"
  key="$CERT_DIR/$user.key"
  csr="$CERT_DIR/$user.csr"
  crt="$CERT_DIR/$user.crt"

  subject="/CN=$user"
  IFS=',' read -ra group_list <<< "$groups"
  for g in "${group_list[@]}"; do subject+="/O=$g"; done

  echo "==> $user ($groups)"
  if [[ ! -f "$key" ]]; then
    openssl genrsa -out "$key" 2048 2>/dev/null
    chmod 600 "$key"
  fi
  openssl req -new -key "$key" -subj "$subject" -out "$csr"

  kc delete csr "$user" --ignore-not-found >/dev/null
  kc apply -f - >/dev/null <<EOF
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: $user
  labels:
    propdev.ru/managed-by: task4-rbac
spec:
  request: $(base64 < "$csr" | tr -d '\n')
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: $CERT_TTL_SECONDS
  usages: ["client auth"]
EOF
  kc certificate approve "$user" >/dev/null

  cert=""
  for _ in $(seq 1 30); do
    cert="$(kc get csr "$user" -o jsonpath='{.status.certificate}')"
    [[ -n "$cert" ]] && break
    sleep 1
  done
  [[ -n "$cert" ]] || { echo "Сертификат для $user не выпущен" >&2; exit 1; }
  echo "$cert" | base64 -d > "$crt"
  kc delete csr "$user" >/dev/null
  rm -f "$csr"

  kubectl config set-credentials "$user" --client-certificate="$crt" --client-key="$key" --embed-certs=true >/dev/null
  kubectl config set-context "$user@$CLUSTER" --cluster="$CLUSTER" --user="$user" >/dev/null
  echo "    контекст $user@$CLUSTER, сертификат действует до $(openssl x509 -in "$crt" -noout -enddate | cut -d= -f2)"
done

echo "Пользователи созданы. Прав у них пока нет: роли — 02-create-roles.sh, привязка — 03-bind-roles.sh"
