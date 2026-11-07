#!/usr/bin/env bash
# =============================================================================
# Task5. Развёртывание четырёх сервисов, применение сетевых политик и проверка.
# Требуется Minikube с CNI, поддерживающим NetworkPolicy:
#   minikube start -p propdev --cni=calico
# Использование: ./deploy-and-test.sh   (или KUBE_CONTEXT=propdev ./deploy-and-test.sh)
# =============================================================================
set -euo pipefail
export MSYS_NO_PATHCONV=1
KUBE_CONTEXT="${KUBE_CONTEXT:-$(kubectl config current-context)}"
kc() { kubectl --context "${KUBE_CONTEXT}" -n default "$@"; }
cd "$(dirname "$0")"

echo ">>> 1. Сервисы (nginx) с метками-ролями"
for role in front-end back-end-api admin-front-end admin-back-end-api; do
  kc get pod "${role}-app" >/dev/null 2>&1 || \
    kc run "${role}-app" --image=nginx --labels "role=${role}" --expose --port 80
done
kc wait --for=condition=Ready pod -l 'role in (front-end,back-end-api,admin-front-end,admin-back-end-api)' --timeout=180s

echo ">>> 2. Сетевые политики"
kc apply -f non-admin-api-allow.yaml

echo ">>> 3. Проверка: тестовый под с меткой роли обращается к сервисам"
# Тестовый alpine-под получает метку роли, от имени которой проверяем доступ;
# под без метки моделирует «любой другой под» в namespace.
fail=0
probe() {   # probe <role-label|none> <target-service> <expected ok|blocked>
  local from="$1" target="$2" exp="$3" labels=()
  [[ "${from}" != "none" ]] && labels=(--labels "role=${from}")
  local name="test-${RANDOM}"
  local got="blocked"
  if kc run "${name}" --rm -i --restart=Never --image=alpine "${labels[@]}" --quiet -- \
       sh -c "wget -qO- --timeout=2 http://${target}-app >/dev/null" >/dev/null 2>&1; then
    got="ok"
  fi
  local mark="OK"; [[ "${got}" == "${exp}" ]] || { mark="FAIL"; fail=1; }
  printf '  [%-4s] %-20s -> %-24s %-8s (ожидалось %s)\n' "${mark}" "${from}" "${target}-app" "${got}" "${exp}"
}

probe front-end          back-end-api        ok
probe back-end-api       front-end           ok
probe admin-front-end    admin-back-end-api  ok
probe admin-back-end-api admin-front-end     ok
probe front-end          admin-back-end-api  blocked
probe admin-front-end    back-end-api        blocked
probe back-end-api       admin-back-end-api  blocked
probe none               back-end-api        blocked
probe none               admin-back-end-api  blocked
probe none               front-end           blocked

echo
if [[ "${fail}" -eq 0 ]]; then echo "Все проверки пройдены"; else echo "Есть несоответствия" >&2; exit 1; fi
