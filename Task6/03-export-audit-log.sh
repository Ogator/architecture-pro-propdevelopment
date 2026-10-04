#!/usr/bin/env bash
# Задание 6. Выгрузка /var/log/audit.log из контейнера API-сервера в Task6/audit.log.
#
# Файл лежит в файловой системе контейнера, а не на узле: kubeadm не даёт добавить API-серверу
# каталог для записи, а образ API-сервера не содержит cat. Поэтому файл читается с узла через
# корневую ФС процесса kube-apiserver (/proc/<pid>/root).
#
# audit.log в git не попадает: на уровне RequestResponse в нём сохраняется содержимое secrets.

set -euo pipefail
cd "$(dirname "$0")"

PROFILE="${PROFILE:-minikube}"

minikube ssh -p "$PROFILE" -- 'sudo cat /proc/$(pgrep -o kube-apiserver)/root/var/log/audit.log' > audit.log
echo "==> $(wc -l < audit.log) событий сохранено в $(pwd)/audit.log"
