#!/usr/bin/env bash
# Задание 6, шаг 1. Перезапуск Minikube с аудитом API-сервера.
#
# kube-apiserver.yaml внутри узла генерируется minikube и перезаписывается, поэтому политика
# подключается снаружи:
#   1. Файл кладётся в ~/.minikube/files/etc/ssl/certs/ на хосте. При старте minikube копирует
#      содержимое ~/.minikube/files/ на узел, а каталог /etc/ssl/certs узла kubeadm монтирует
#      в контейнер API-сервера (единственный подходящий каталог из уже смонтированных).
#   2. Флаги --extra-config передают API-серверу путь к политике и к журналу.
#
# Журнал пишется в /var/log/audit.log внутри контейнера API-сервера, выгрузка — 03-export-audit-log.sh.

set -euo pipefail
cd "$(dirname "$0")"

PROFILE="${PROFILE:-minikube}"
SYNC_DIR="${MINIKUBE_HOME:-$HOME/.minikube}/files/etc/ssl/certs"

mkdir -p "$SYNC_DIR"
cp audit-policy.yaml "$SYNC_DIR/audit-policy.yaml"
echo "==> Политика скопирована в $SYNC_DIR/audit-policy.yaml"

echo "==> Перезапуск minikube с аудитом"
minikube stop -p "$PROFILE"
minikube start -p "$PROFILE" \
  --extra-config=apiserver.audit-policy-file=/etc/ssl/certs/audit-policy.yaml \
  --extra-config=apiserver.audit-log-path=/var/log/audit.log

echo "==> Проверка флагов API-сервера"
kubectl --context "$PROFILE" -n kube-system get pod "kube-apiserver-$PROFILE" \
  -o jsonpath='{range .spec.containers[0].command[*]}{@}{"\n"}{end}' | grep -- '--audit-'
