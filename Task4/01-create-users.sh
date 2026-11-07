#!/usr/bin/env bash
# =============================================================================
# Task4 / Шаг 3. Создание пользователей Kubernetes (PropDevelopment)
#
# Пользователи создаются через X.509-сертификаты, подписанные CA кластера
# (Kubernetes CertificateSigningRequest API, signer kubernetes.io/kube-apiserver-client).
#   CN (Common Name) -> имя пользователя
#   O  (Organization) -> группа пользователя (используется в RoleBinding/ClusterRoleBinding)
#
# Для каждого пользователя скрипт:
#   1. генерирует закрытый ключ и CSR (openssl);
#   2. создаёт объект CertificateSigningRequest и одобряет его;
#   3. сохраняет выданный сертификат;
#   4. добавляет пользователя и контекст в kubeconfig.
#
# Требования: kubectl с правами администратора кластера, openssl.
# Использование: ./01-create-users.sh            (текущий контекст kubectl)
#                KUBE_CONTEXT=propdev ./01-create-users.sh
# Ключи и сертификаты сохраняются в ./users (каталог исключён из Git).
# =============================================================================
set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash на Windows: не преобразовывать "/CN=..." в путь

KUBE_CONTEXT="${KUBE_CONTEXT:-$(kubectl config current-context)}"
CLUSTER_NAME="$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"${KUBE_CONTEXT}\")].context.cluster}")"
USERS_DIR="$(cd "$(dirname "$0")" && pwd)/users"
CERT_TTL_SECONDS="${CERT_TTL_SECONDS:-2592000}"   # 30 дней: короткоживущие сертификаты
mkdir -p "${USERS_DIR}"
cd "${USERS_DIR}"   # относительные пути: работают и в Linux/macOS, и в Git Bash на Windows

# -----------------------------------------------------------------------------
# Пользователь : группа (организационная роль, см. roles.md)
# -----------------------------------------------------------------------------
USERS=(
  "anna.sokolova:propdev:viewers"              # бизнес-аналитик — только просмотр
  "boris.ivanov:propdev:platform-ops"          # инженер платформы — настройка кластера
  "elena.smirnova:propdev:security"            # специалист по ИБ — привилегированный доступ
  "dmitry.kozlov:propdev:sales-developers"     # разработчик домена «Продажи»
  "olga.novikova:propdev:housing-devops"       # DevOps-инженер домена «ЖКУ» (в т.ч. «Умный дом»)
  "pavel.orlov:propdev:finance-operations"     # инженер по эксплуатации домена «Финансы»
)

kc() { kubectl --context "${KUBE_CONTEXT}" "$@"; }

for entry in "${USERS[@]}"; do
  user="${entry%%:*}"
  group="${entry#*:}"
  key="${user}.key"
  csr="${user}.csr"
  crt="${user}.crt"

  echo ">>> Пользователь ${user} (группа ${group})"

  # 1. Ключ и CSR
  [[ -f "${key}" ]] || openssl genrsa -out "${key}" 2048 2>/dev/null
  openssl req -new -key "${key}" -out "${csr}" -subj "/CN=${user}/O=${group}"

  # 2. CertificateSigningRequest в кластере (пересоздаём, если уже был)
  kc delete csr "${user}" --ignore-not-found >/dev/null
  cat <<EOF | kc apply -f - >/dev/null
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: ${user}
  labels:
    app.kubernetes.io/part-of: propdevelopment-rbac
spec:
  request: $(base64 < "${csr}" | tr -d '\n')
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: ${CERT_TTL_SECONDS}
  usages:
    - client auth
EOF
  kc certificate approve "${user}" >/dev/null

  # 3. Ожидаем выпуск сертификата
  for _ in $(seq 1 20); do
    cert_b64="$(kc get csr "${user}" -o jsonpath='{.status.certificate}')"
    [[ -n "${cert_b64}" ]] && break
    sleep 1
  done
  [[ -n "${cert_b64}" ]] || { echo "Сертификат для ${user} не выпущен" >&2; exit 1; }
  echo "${cert_b64}" | base64 -d > "${crt}"

  # 4. kubeconfig: учётные данные + контекст пользователя
  kubectl config set-credentials "${user}" \
    --client-certificate="${crt}" --client-key="${key}" --embed-certs=true >/dev/null
  kubectl config set-context "${user}@${CLUSTER_NAME}" \
    --cluster="${CLUSTER_NAME}" --user="${user}" >/dev/null

  echo "    контекст: ${user}@${CLUSTER_NAME}"
done

echo
echo "Готово. Пользователи созданы, сертификаты: ${USERS_DIR}"
echo "Права появятся после выполнения 02-create-roles.sh и 03-bind-roles.sh"
