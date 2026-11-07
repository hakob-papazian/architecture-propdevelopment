#!/usr/bin/env bash
# =============================================================================
# Task4 / Шаг 5. Связывание пользователей (через группы) с ролями
#
# Права выдаются ГРУППАМ, а не отдельным людям: группа берётся из поля O
# сертификата пользователя (см. 01-create-users.sh). При переходе сотрудника
# в другую команду достаточно перевыпустить сертификат с новой группой;
# при увольнении — не продлевать сертификат (TTL 30 дней) и отозвать доступ
# у провайдера идентификации (в продуктиве — OIDC через Keycloak/AD).
#
# Использование: ./03-bind-roles.sh            — создать привязки и проверить права
#                ./03-bind-roles.sh --no-check — только создать привязки
# =============================================================================
set -euo pipefail
KUBE_CONTEXT="${KUBE_CONTEXT:-$(kubectl config current-context)}"
kc() { kubectl --context "${KUBE_CONTEXT}" "$@"; }

echo ">>> Кластерные привязки"
cat <<'EOF' | kc apply -f -
# Аварийный доступ (break-glass): 1–2 руководителя платформы, только по процедуре
# с уведомлением ИБ. Обычная работа под этой группой запрещена.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: propdev-cluster-admins
  labels: { app.kubernetes.io/part-of: propdevelopment-rbac }
subjects:
  - { kind: Group, name: "propdev:cluster-admins", apiGroup: rbac.authorization.k8s.io }
roleRef: { kind: ClusterRole, name: cluster-admin, apiGroup: rbac.authorization.k8s.io }
---
# Специалист по ИБ: просмотр секретов, управление RBAC и сетевыми политиками
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: propdev-security-admin
  labels: { app.kubernetes.io/part-of: propdevelopment-rbac }
subjects:
  - { kind: Group, name: "propdev:security", apiGroup: rbac.authorization.k8s.io }
roleRef: { kind: ClusterRole, name: propdev-security-admin, apiGroup: rbac.authorization.k8s.io }
---
# Платформенная команда (DevOps/SRE): настройка кластера
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: propdev-platform-operator
  labels: { app.kubernetes.io/part-of: propdevelopment-rbac }
subjects:
  - { kind: Group, name: "propdev:platform-ops", apiGroup: rbac.authorization.k8s.io }
roleRef: { kind: ClusterRole, name: propdev-platform-operator, apiGroup: rbac.authorization.k8s.io }
---
# Только просмотр: владельцы продуктов, бизнес-аналитики, аналитики BI, аудиторы
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: propdev-cluster-viewer
  labels: { app.kubernetes.io/part-of: propdevelopment-rbac }
subjects:
  - { kind: Group, name: "propdev:viewers", apiGroup: rbac.authorization.k8s.io }
  - { kind: Group, name: "propdev:platform-ops", apiGroup: rbac.authorization.k8s.io }
roleRef: { kind: ClusterRole, name: propdev-cluster-viewer, apiGroup: rbac.authorization.k8s.io }
EOF

# -----------------------------------------------------------------------------
# Привязки в namespace по доменам (организационная структура):
#   домен   -> namespace(ы)
# -----------------------------------------------------------------------------
declare -A DOMAIN_NAMESPACES=(
  [sales]="sales"
  [housing]="housing smart-home"
  [finance]="finance"
  [data]="data"
)

bind_ns() {   # bind_ns <namespace> <binding-name> <clusterrole> <group...>
  local ns="$1" name="$2" role="$3"; shift 3
  local subjects=""
  for g in "$@"; do
    subjects+="  - { kind: Group, name: \"${g}\", apiGroup: rbac.authorization.k8s.io }"$'\n'
  done
  cat <<EOF | kc apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${name}
  namespace: ${ns}
  labels: { app.kubernetes.io/part-of: propdevelopment-rbac }
subjects:
${subjects}roleRef: { kind: ClusterRole, name: ${role}, apiGroup: rbac.authorization.k8s.io }
EOF
}

echo ">>> Привязки по доменам"
for domain in "${!DOMAIN_NAMESPACES[@]}"; do
  for ns in ${DOMAIN_NAMESPACES[$domain]}; do
    # разработчики и DevOps-инженер домена — развёртывание сервисов
    bind_ns "${ns}" "${domain}-developers" propdev-ns-developer \
      "propdev:${domain}-developers" "propdev:${domain}-devops"
    # инженеры по эксплуатации домена
    bind_ns "${ns}" "${domain}-operations" propdev-ns-operations "propdev:${domain}-operations"
    # секреты домена — только DevOps-инженер продуктовой команды
    bind_ns "${ns}" "${domain}-secrets" propdev-ns-secrets-manager "propdev:${domain}-devops"
  done
done

# Платформенные секреты (TLS-сертификаты шлюза, конфигурация Keycloak/Vault)
bind_ns platform platform-secrets propdev-ns-secrets-manager "propdev:platform-ops"

[[ "${1:-}" == "--no-check" ]] && exit 0

# -----------------------------------------------------------------------------
# Проверка: kubectl auth can-i от имени пользователей и их групп
# -----------------------------------------------------------------------------
echo
echo ">>> Проверка прав (ожидаемый результат в скобках)"
fail=0
check() {   # check <expected yes|no> <user> <group> <verb> <resource> [namespace]
  local exp="$1" user="$2" group="$3" verb="$4" res="$5" ns="${6:-}"
  # "pods/log" -> ресурс pods + --subresource=log (иначе kubectl трактует "log" как имя объекта)
  local args=(auth can-i "${verb}" "${res%%/*}" --as="${user}" --as-group="${group}")
  [[ "${res}" == */* ]] && args+=(--subresource="${res#*/}")
  if [[ -n "${ns}" ]]; then args+=(-n "${ns}"); else args+=(--all-namespaces); fi
  local got; got="$(kc "${args[@]}" 2>/dev/null || true)"
  local mark="OK"; [[ "${got}" == "${exp}" ]] || { mark="FAIL"; fail=1; }
  printf '  [%-4s] %-15s %-7s %-24s %-11s -> %-3s (%s)\n' \
    "${mark}" "${user}" "${verb}" "${res}" "${ns:-*}" "${got}" "${exp}"
}

check yes anna.sokolova  propdev:viewers           list   pods
check no  anna.sokolova  propdev:viewers           get    secrets                  sales
check no  anna.sokolova  propdev:viewers           get    pods/log                 sales
check no  anna.sokolova  propdev:viewers           delete pods                     sales

check yes boris.ivanov   propdev:platform-ops      create namespaces
check yes boris.ivanov   propdev:platform-ops      patch  nodes
check yes boris.ivanov   propdev:platform-ops      create networkpolicies.networking.k8s.io sales
check no  boris.ivanov   propdev:platform-ops      get    secrets                  sales
check no  boris.ivanov   propdev:platform-ops      create clusterrolebindings.rbac.authorization.k8s.io
check yes boris.ivanov   propdev:platform-ops      get    secrets                  platform

check yes elena.smirnova propdev:security          get    secrets                  finance
check yes elena.smirnova propdev:security          create rolebindings.rbac.authorization.k8s.io sales
check no  elena.smirnova propdev:security          delete deployments.apps         sales

check yes dmitry.kozlov  propdev:sales-developers  create deployments.apps         sales
check no  dmitry.kozlov  propdev:sales-developers  create deployments.apps         housing
check no  dmitry.kozlov  propdev:sales-developers  get    secrets                  sales
check no  dmitry.kozlov  propdev:sales-developers  create pods/exec                sales

check yes olga.novikova  propdev:housing-devops    get    secrets                  smart-home
check yes olga.novikova  propdev:housing-devops    create deployments.apps         housing
check no  olga.novikova  propdev:housing-devops    get    secrets                  finance

check yes pavel.orlov    propdev:finance-operations get   pods/log                 finance
check yes pavel.orlov    propdev:finance-operations delete pods                    finance
check no  pavel.orlov    propdev:finance-operations create deployments.apps        finance
check no  pavel.orlov    propdev:finance-operations get   secrets                  finance

echo
if [[ "${fail}" -eq 0 ]]; then echo "Все проверки пройдены"; else echo "Есть несоответствия" >&2; exit 1; fi
