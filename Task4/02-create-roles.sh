#!/usr/bin/env bash
# Задание 4, шаг 4. Создание namespace доменов и ролей.
#
# Роли соответствуют таблице в roles.md.
# Роли уровня кластера — ClusterRole, назначаются через ClusterRoleBinding:
#   propdev-cluster-viewer     — просмотр всего кластера без secrets, configmaps и логов
#   propdev-cluster-operator   — настройка ресурсов уровня кластера, без приложений доменов и secrets
#   propdev-security-admin     — secrets и выдача ролей propdev-* (привилегированная)
# Роли namespace — Role, создаются в каждом namespace отдельно и не могут действовать за его пределами:
#   propdev-platform-component — системные компоненты, в платформенных namespace, без secrets
#   propdev-ns-admin           — полный доступ к namespace домена, включая secrets (привилегированная)
#   propdev-ns-developer       — разработка в namespace домена без secrets
#   propdev-ns-viewer          — просмотр namespace домена
# Аварийная роль — встроенная cluster-admin.
#
# Запуск: ./02-create-roles.sh

set -euo pipefail
source "$(dirname "$0")/common.sh"

echo "==> Namespace доменов"
for ns in "${DOMAINS[@]}"; do
  kc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $ns
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
EOF
done

echo "==> Роли уровня кластера"
kc apply -f - <<'EOF'
# ---------------------------------------------------------------- просмотр всего кластера
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: propdev-cluster-viewer
  labels:
    propdev.ru/managed-by: task4-rbac
rules:
  - apiGroups: [""]
    resources: [namespaces, nodes, pods, services, endpoints, persistentvolumeclaims, persistentvolumes,
                events, serviceaccounts, resourcequotas, limitranges, replicationcontrollers]
    verbs: [get, list, watch]
  - apiGroups: [apps]
    resources: [deployments, statefulsets, daemonsets, replicasets]
    verbs: [get, list, watch]
  - apiGroups: [batch]
    resources: [jobs, cronjobs]
    verbs: [get, list, watch]
  - apiGroups: [autoscaling]
    resources: [horizontalpodautoscalers]
    verbs: [get, list, watch]
  - apiGroups: [policy]
    resources: [poddisruptionbudgets]
    verbs: [get, list, watch]
  - apiGroups: [networking.k8s.io]
    resources: [ingresses, ingressclasses, networkpolicies]
    verbs: [get, list, watch]
  - apiGroups: [storage.k8s.io]
    resources: [storageclasses]
    verbs: [get, list, watch]
  - apiGroups: [discovery.k8s.io]
    resources: [endpointslices]
    verbs: [get, list, watch]
  - apiGroups: [events.k8s.io]
    resources: [events]
    verbs: [get, list, watch]
  - apiGroups: [metrics.k8s.io]
    resources: [pods, nodes]
    verbs: [get, list, watch]
---
# ---------------------------------------------------------------- настройка кластера (ресурсы уровня кластера)
# Приложения доменов не трогает. Просмотр подов и workloads для диагностики и drain
# даёт дополнительно назначенная propdev-cluster-viewer.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: propdev-cluster-operator
  labels:
    propdev.ru/managed-by: task4-rbac
rules:
  # namespace: создание и удаление; метки Pod Security меняет только security-admin
  - apiGroups: [""]
    resources: [namespaces]
    verbs: [get, list, watch, create, delete]
  # cordon/uncordon
  - apiGroups: [""]
    resources: [nodes]
    verbs: [get, list, watch, update, patch]
  # drain
  - apiGroups: [""]
    resources: [pods/eviction]
    verbs: [create]
  # квоты и лимиты — распределение ресурсов между доменами
  - apiGroups: [""]
    resources: [persistentvolumes, resourcequotas, limitranges]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [storage.k8s.io]
    resources: [storageclasses, volumeattachments, csidrivers, csinodes]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [apiextensions.k8s.io]
    resources: [customresourcedefinitions]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [scheduling.k8s.io]
    resources: [priorityclasses]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [networking.k8s.io]
    resources: [ingressclasses]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [rbac.authorization.k8s.io]
    resources: [roles, rolebindings, clusterroles, clusterrolebindings]
    verbs: [get, list, watch]
---
# ---------------------------------------------------------------- секреты и права доступа (привилегированная)
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: propdev-security-admin
  labels:
    propdev.ru/managed-by: task4-rbac
    propdev.ru/privileged: "true"
rules:
  - apiGroups: [""]
    resources: [secrets]
    verbs: [get, list, watch, create, update, patch, delete]
  # метки Pod Security на namespace
  - apiGroups: [""]
    resources: [namespaces]
    verbs: [get, list, watch, update, patch]
  # сами роли менять нельзя, только привязывать
  - apiGroups: [rbac.authorization.k8s.io]
    resources: [roles, clusterroles]
    verbs: [get, list, watch]
  - apiGroups: [rbac.authorization.k8s.io]
    resources: [rolebindings, clusterrolebindings]
    verbs: [get, list, watch, create, update, patch, delete]
  # выдавать можно только роли propdev-*, cluster-admin — нельзя
  - apiGroups: [rbac.authorization.k8s.io]
    resources: [clusterroles]
    verbs: [bind]
    resourceNames: [propdev-cluster-viewer, propdev-cluster-operator]
  - apiGroups: [rbac.authorization.k8s.io]
    resources: [roles]
    verbs: [bind]
    resourceNames: [propdev-platform-component, propdev-ns-admin, propdev-ns-developer, propdev-ns-viewer]
  - apiGroups: [networking.k8s.io]
    resources: [networkpolicies]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [admissionregistration.k8s.io]
    resources: [validatingwebhookconfigurations, mutatingwebhookconfigurations,
                validatingadmissionpolicies, validatingadmissionpolicybindings]
    verbs: [get, list, watch, create, update, patch, delete]
EOF

# ---------------------------------------------------------------- роли namespace
# Правила каждой роли описаны один раз и создаются как Role в каждом нужном namespace.

ns_role() {   # namespace роль функция-правил [privileged]
  kc apply -f - >/dev/null <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: $2
  namespace: $1
  labels:
    propdev.ru/managed-by: task4-rbac
$( [[ "${4:-}" == privileged ]] && echo '    propdev.ru/privileged: "true"' )
$($3)
EOF
  echo "    Role $1/$2"
}

# Системные компоненты платформы. От propdev-ns-developer отличается daemonsets
# и сервисными аккаунтами, от propdev-ns-admin — отсутствием secrets и exec.
rules_platform_component() { cat <<'EOF'
rules:
  - apiGroups: [""]
    resources: [pods]
    verbs: [get, list, watch, delete]
  - apiGroups: [""]
    resources: [pods/log]
    verbs: [get, list]
  - apiGroups: [""]
    resources: [services, configmaps, serviceaccounts, persistentvolumeclaims]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [""]
    resources: [endpoints, events, resourcequotas, limitranges]
    verbs: [get, list, watch]
  - apiGroups: [apps]
    resources: [deployments, statefulsets, daemonsets, replicasets, deployments/scale, statefulsets/scale]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [batch]
    resources: [jobs, cronjobs]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [autoscaling]
    resources: [horizontalpodautoscalers]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [policy]
    resources: [poddisruptionbudgets]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [networking.k8s.io]
    resources: [networkpolicies]
    verbs: [get, list, watch]
  - apiGroups: [discovery.k8s.io]
    resources: [endpointslices]
    verbs: [get, list, watch]
  - apiGroups: [events.k8s.io]
    resources: [events]
    verbs: [get, list, watch]
  - apiGroups: [metrics.k8s.io]
    resources: [pods]
    verbs: [get, list, watch]
EOF
}

# Администратор домена (привилегированная)
rules_ns_admin() { cat <<'EOF'
rules:
  - apiGroups: [""]
    resources: [pods, services, endpoints, configmaps, secrets, persistentvolumeclaims, serviceaccounts,
                replicationcontrollers]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [""]
    resources: [pods/log]
    verbs: [get, list]
  - apiGroups: [""]
    resources: [pods/exec, pods/portforward, pods/attach, pods/eviction]
    verbs: [create, get]
  - apiGroups: [""]
    resources: [events, resourcequotas, limitranges]
    verbs: [get, list, watch]
  - apiGroups: [apps]
    resources: [deployments, statefulsets, daemonsets, replicasets, deployments/scale, statefulsets/scale]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [batch]
    resources: [jobs, cronjobs]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [autoscaling]
    resources: [horizontalpodautoscalers]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [policy]
    resources: [poddisruptionbudgets]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [networking.k8s.io]
    resources: [ingresses, networkpolicies]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [discovery.k8s.io]
    resources: [endpointslices]
    verbs: [get, list, watch]
  - apiGroups: [events.k8s.io]
    resources: [events]
    verbs: [get, list, watch]
  - apiGroups: [metrics.k8s.io]
    resources: [pods]
    verbs: [get, list, watch]
  - apiGroups: [rbac.authorization.k8s.io]
    resources: [roles, rolebindings]
    verbs: [get, list, watch]
EOF
}

# Разработчик домена
rules_ns_developer() { cat <<'EOF'
rules:
  - apiGroups: [""]
    resources: [pods]
    verbs: [get, list, watch, delete]
  - apiGroups: [""]
    resources: [pods/log]
    verbs: [get, list]
  - apiGroups: [""]
    resources: [services, configmaps, persistentvolumeclaims]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [""]
    resources: [endpoints, events, serviceaccounts, resourcequotas, limitranges]
    verbs: [get, list, watch]
  - apiGroups: [apps]
    resources: [deployments, statefulsets, replicasets, deployments/scale, statefulsets/scale]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [batch]
    resources: [jobs, cronjobs]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [autoscaling]
    resources: [horizontalpodautoscalers]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [policy]
    resources: [poddisruptionbudgets]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [networking.k8s.io]
    resources: [ingresses]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [networking.k8s.io]
    resources: [networkpolicies]
    verbs: [get, list, watch]
  - apiGroups: [discovery.k8s.io]
    resources: [endpointslices]
    verbs: [get, list, watch]
  - apiGroups: [events.k8s.io]
    resources: [events]
    verbs: [get, list, watch]
  - apiGroups: [metrics.k8s.io]
    resources: [pods]
    verbs: [get, list, watch]
EOF
}

# Просмотр домена
rules_ns_viewer() { cat <<'EOF'
rules:
  - apiGroups: [""]
    resources: [pods, services, endpoints, persistentvolumeclaims, events, serviceaccounts,
                resourcequotas, limitranges, replicationcontrollers]
    verbs: [get, list, watch]
  - apiGroups: [apps]
    resources: [deployments, statefulsets, daemonsets, replicasets]
    verbs: [get, list, watch]
  - apiGroups: [batch]
    resources: [jobs, cronjobs]
    verbs: [get, list, watch]
  - apiGroups: [autoscaling]
    resources: [horizontalpodautoscalers]
    verbs: [get, list, watch]
  - apiGroups: [policy]
    resources: [poddisruptionbudgets]
    verbs: [get, list, watch]
  - apiGroups: [networking.k8s.io]
    resources: [ingresses, networkpolicies]
    verbs: [get, list, watch]
  - apiGroups: [discovery.k8s.io]
    resources: [endpointslices]
    verbs: [get, list, watch]
  - apiGroups: [events.k8s.io]
    resources: [events]
    verbs: [get, list, watch]
  - apiGroups: [metrics.k8s.io]
    resources: [pods]
    verbs: [get, list, watch]
EOF
}

echo "==> Роли платформенных namespace"
for ns in $(existing_platform_namespaces); do
  ns_role "$ns" propdev-platform-component rules_platform_component
done

echo "==> Роли namespace доменов"
for ns in "${DOMAINS[@]}"; do
  ns_role "$ns" propdev-ns-admin     rules_ns_admin privileged
  ns_role "$ns" propdev-ns-developer rules_ns_developer
  ns_role "$ns" propdev-ns-viewer    rules_ns_viewer
done
