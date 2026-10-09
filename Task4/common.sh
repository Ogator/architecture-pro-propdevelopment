# Общие параметры для 02-create-roles.sh и 03-bind-roles.sh. Не запускается отдельно.

ADMIN_CONTEXT="${ADMIN_CONTEXT:-minikube}"

# Namespace доменов. Создаются в 02-create-roles.sh.
DOMAINS=(sales housing finance data)

# Платформенные namespace. Создаются при установке компонентов, а не этими скриптами, поэтому
# отсутствующие пропускаются. При появлении нового namespace (например, при установке мониторинга)
# нужно перезапустить 02 и 03. kube-system намеренно не входит.
PLATFORM_NAMESPACES=(ingress-nginx kubernetes-dashboard monitoring logging tracing cert-manager)

kc() { kubectl --context "$ADMIN_CONTEXT" "$@"; }

existing_platform_namespaces() {
  local ns
  for ns in "${PLATFORM_NAMESPACES[@]}"; do
    if kc get namespace "$ns" >/dev/null 2>&1; then
      echo "$ns"
    else
      echo "    namespace $ns не найден, пропущен" >&2
    fi
  done
}
