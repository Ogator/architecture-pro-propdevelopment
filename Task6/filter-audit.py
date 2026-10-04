#!/usr/bin/env python3
"""Задание 6. Фильтрация audit.log: отбор подозрительных событий в audit-extract.json.

Категории:
  secrets           — чтение secrets кем-то, кроме системных компонентов, а также любые отказы
  privileged-pod    — создание или изменение пода с privileged: true
  exec              — exec / attach / portforward в под
  rbac-binding      — создание, изменение, удаление RoleBinding и ClusterRoleBinding
                      (кроме служебных привязок, которые kubeadm пересоздаёт при старте)
  audit-tampering   — изменение объектов с audit в имени и перезапуск API-сервера
                      (политика аудита — файл на узле, её удаление в журнал API не попадает)

Из каждого события берётся стадия ResponseComplete (иначе одно действие попадает в журнал дважды).
Тела ответов не копируются: для secrets в них лежат сами секреты.

Запуск: ./filter-audit.py [audit.log] [-o audit-extract.json]
"""

import argparse
import json
import sys

# Системные учётные записи, которым чтение secrets положено по работе.
TRUSTED_SECRET_READERS_PREFIXES = (
    "system:kube-controller-manager",
    "system:kube-scheduler",
    "system:apiserver",
    "system:node:",
    "system:serviceaccount:kube-system:",
    "system:serviceaccount:ingress-nginx:",
    "system:serviceaccount:kubernetes-dashboard:",
)
# minikube — учётная запись, которой minikube на узле применяет манифесты дополнений.
TRUSTED_SECRET_READERS = {"minikube"}

EXEC_SUBRESOURCES = {"exec", "attach", "portforward"}
BINDING_RESOURCES = {"rolebindings", "clusterrolebindings"}
WRITE_VERBS = {"create", "update", "patch", "delete"}


def effective_user(event):
    """Пользователь, от имени которого выполнен запрос (с учётом --as)."""
    imp = event.get("impersonatedUser")
    return (imp or event.get("user", {})).get("username", "")


def is_privileged(pod_spec):
    containers = (pod_spec.get("containers") or []) + (pod_spec.get("initContainers") or [])
    return any((c.get("securityContext") or {}).get("privileged") is True for c in containers)


def classify(event):
    """Возвращает список (категория, причина) для события."""
    ref = event.get("objectRef") or {}
    resource, sub, verb = ref.get("resource"), ref.get("subresource"), event.get("verb")
    code = (event.get("responseStatus") or {}).get("code")
    found = []

    if resource == "secrets" and verb in {"get", "list", "watch"}:
        user = effective_user(event)
        if code == 403:
            found.append(("secrets", f"отказ в доступе к secrets для {user}"))
        elif user not in TRUSTED_SECRET_READERS and not user.startswith(TRUSTED_SECRET_READERS_PREFIXES):
            found.append(("secrets", f"secrets прочитаны учётной записью {user}"))

    if resource == "pods" and not sub and verb in {"create", "update", "patch"}:
        spec = (event.get("requestObject") or {}).get("spec") or {}
        if is_privileged(spec):
            found.append(("privileged-pod", "под с securityContext.privileged: true"))

    if resource == "pods" and sub in EXEC_SUBRESOURCES:
        found.append(("exec", f"{sub} в под {ref.get('namespace')}/{ref.get('name')}"))

    bootstrap = (event.get("userAgent") or "").startswith("kubeadm/")
    if resource in BINDING_RESOURCES and verb in WRITE_VERBS and not bootstrap:
        role = ((event.get("requestObject") or {}).get("roleRef") or {}).get("name")
        reason = f"{verb} {resource}"
        if role:
            reason += f" на роль {role}"
        if role == "cluster-admin":
            reason += " — выдача полного доступа к кластеру"
        found.append(("rbac-binding", reason))

    target = f"{ref.get('name') or ''} {event.get('requestURI') or ''}".lower()
    if "audit" in target and verb in WRITE_VERBS:
        found.append(("audit-tampering", f"{verb} объекта с аудитом в имени"))
    if (resource == "pods" and not sub and verb == "create" and code == 201
            and (ref.get("name") or "").startswith("kube-apiserver-")):
        found.append(("audit-tampering", "перезапуск API-сервера: могли смениться флаги и политика аудита"))

    return found


def compact(event, categories):
    """Выжимка события: кто, что, где, результат. Тело запроса — только для подов и привязок."""
    ref = event.get("objectRef") or {}
    out = {
        "categories": [c for c, _ in categories],
        "reasons": [r for _, r in categories],
        "time": event.get("stageTimestamp"),
        "auditID": event.get("auditID"),
        "user": event.get("user", {}).get("username"),
        "groups": event.get("user", {}).get("groups"),
        "impersonatedUser": (event.get("impersonatedUser") or {}).get("username"),
        "sourceIPs": event.get("sourceIPs"),
        "userAgent": event.get("userAgent"),
        "verb": event.get("verb"),
        "requestURI": event.get("requestURI"),
        "objectRef": ref,
        "responseStatus": event.get("responseStatus"),
        "decision": (event.get("annotations") or {}).get("authorization.k8s.io/decision"),
        "reason": (event.get("annotations") or {}).get("authorization.k8s.io/reason"),
    }
    if ref.get("resource") in {"pods", *BINDING_RESOURCES} and event.get("requestObject"):
        out["requestObject"] = event["requestObject"]
    return {k: v for k, v in out.items() if v not in (None, [], {})}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("log", nargs="?", default="audit.log")
    parser.add_argument("-o", "--output", default="audit-extract.json")
    args = parser.parse_args()

    extract, total = [], 0
    with open(args.log, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line.startswith("{"):
                continue
            event = json.loads(line)
            if event.get("stage") != "ResponseComplete":
                continue
            total += 1
            categories = classify(event)
            if categories:
                extract.append(compact(event, categories))

    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(extract, f, ensure_ascii=False, indent=2)

    print(f"Событий (ResponseComplete): {total}, подозрительных: {len(extract)} -> {args.output}\n")
    for e in extract:
        who = e.get("user", "")
        if e.get("impersonatedUser"):
            who += f" (как {e['impersonatedUser']})"
        ref = e.get("objectRef", {})
        target = "/".join(filter(None, [ref.get("namespace"), ref.get("resource"), ref.get("name")]))
        if ref.get("subresource"):
            target += f"/{ref['subresource']}"
        code = e.get("responseStatus", {}).get("code", "")
        print(f"{e.get('time', '')[:19]}  {','.join(e['categories']):<16} {who:<55} {e.get('verb', ''):<7} {target}  [{code}]")
    return 0


if __name__ == "__main__":
    sys.exit(main())
