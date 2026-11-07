#!/usr/bin/env bash
# =============================================================================
# Task4 / Шаг 4. Создание ролей Kubernetes (PropDevelopment)
#
# 1. Пространства имён по организационной структуре (доменам) компании.
# 2. Кластерные роли (ClusterRole + ClusterRoleBinding):
#      propdev-cluster-viewer      — только просмотр, без секретов и логов
#      propdev-platform-operator   — настройка кластера, без секретов и RBAC
#      propdev-security-admin      — привилегированная: просмотр секретов, управление RBAC
#      cluster-admin (встроенная)  — аварийный доступ (break-glass), не создаётся здесь
# 3. Роли уровня пространства имён (ClusterRole-шаблоны, выдаются через RoleBinding
#    только в namespace своего домена):
#      propdev-ns-developer        — развёртывание сервисов домена
#      propdev-ns-operations       — эксплуатация: просмотр, логи, перезапуск, масштабирование
#      propdev-ns-secrets-manager  — управление секретами домена (DevOps-инженер)
#
# Использование: ./02-create-roles.sh   (или KUBE_CONTEXT=propdev ./02-create-roles.sh)
# =============================================================================
set -euo pipefail
KUBE_CONTEXT="${KUBE_CONTEXT:-$(kubectl config current-context)}"
kc() { kubectl --context "${KUBE_CONTEXT}" "$@"; }

echo ">>> Пространства имён"
cat <<'EOF' | kc apply -f -
# Домен «Продажи»: витрина, client-mart, client-tour, client-crm, client-mart-estate
apiVersion: v1
kind: Namespace
metadata:
  name: sales
  labels: { propdev/domain: sales, pod-security.kubernetes.io/enforce: baseline }
---
# Домен «ЖКУ»: tenant-core-app, CRM собственников
apiVersion: v1
kind: Namespace
metadata:
  name: housing
  labels: { propdev/domain: housing, pod-security.kubernetes.io/enforce: baseline }
---
# Домен «ЖКУ», новые сервисы «Умный дом» (Task3): smart-home-service, notification-service
apiVersion: v1
kind: Namespace
metadata:
  name: smart-home
  labels: { propdev/domain: housing, pod-security.kubernetes.io/enforce: restricted }
---
# Домен «Финансы»: accountant-service-1
apiVersion: v1
kind: Namespace
metadata:
  name: finance
  labels: { propdev/domain: finance, pod-security.kubernetes.io/enforce: restricted }
---
# Домен «Дата»: ETL/CDC, BI
apiVersion: v1
kind: Namespace
metadata:
  name: data
  labels: { propdev/domain: data, pod-security.kubernetes.io/enforce: baseline }
---
# Платформа: API Gateway, Keycloak, Vault, мониторинг/SIEM-агенты
apiVersion: v1
kind: Namespace
metadata:
  name: platform
  labels: { propdev/domain: platform, pod-security.kubernetes.io/enforce: baseline }
EOF

echo ">>> Кластерные роли"
cat <<'EOF' | kc apply -f -
# -----------------------------------------------------------------------------
# Только просмотр ресурсов кластера. Нет доступа к Secret, логам подов (могут
# содержать ПДн), exec/port-forward. Изменять ничего нельзя.
# -----------------------------------------------------------------------------
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: propdev-cluster-viewer
  labels: { app.kubernetes.io/part-of: propdevelopment-rbac }
rules:
  - apiGroups: [""]
    resources: [pods, services, endpoints, configmaps, persistentvolumeclaims,
                persistentvolumes, namespaces, nodes, events, serviceaccounts,
                replicationcontrollers, resourcequotas, limitranges]
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
  - apiGroups: [metrics.k8s.io]
    resources: [pods, nodes]
    verbs: [get, list]
---
# -----------------------------------------------------------------------------
# Настройка кластера: узлы, namespace, хранилища, сеть, квоты, CRD, admission-
# вебхуки, рабочие нагрузки во всех namespace. НЕТ доступа к Secret и к
# изменению RBAC (нельзя выдать себе дополнительные права), нет exec в поды.
# -----------------------------------------------------------------------------
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: propdev-platform-operator
  labels: { app.kubernetes.io/part-of: propdevelopment-rbac }
rules:
  - apiGroups: [""]
    resources: [nodes]
    verbs: [get, list, watch, patch, update]          # cordon/drain, метки, taints
  - apiGroups: [""]
    resources: [namespaces, persistentvolumes, resourcequotas, limitranges]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [""]
    resources: [pods, services, endpoints, configmaps, persistentvolumeclaims,
                serviceaccounts, replicationcontrollers]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [""]
    resources: [pods/log, events]
    verbs: [get, list, watch]
  - apiGroups: [""]
    resources: [pods/eviction]
    verbs: [create]
  - apiGroups: [apps]
    resources: [deployments, statefulsets, daemonsets, replicasets,
                deployments/scale, statefulsets/scale]
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
    resources: [ingresses, ingressclasses, networkpolicies]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [storage.k8s.io]
    resources: [storageclasses, volumeattachments, csidrivers, csinodes]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [scheduling.k8s.io]
    resources: [priorityclasses]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [apiextensions.k8s.io]
    resources: [customresourcedefinitions]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [admissionregistration.k8s.io]
    resources: [mutatingwebhookconfigurations, validatingwebhookconfigurations,
                validatingadmissionpolicies, validatingadmissionpolicybindings]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [discovery.k8s.io]
    resources: [endpointslices]
    verbs: [get, list, watch]
  - apiGroups: [metrics.k8s.io]
    resources: [pods, nodes]
    verbs: [get, list]
  # Просмотр (но не изменение) RBAC — чтобы видеть, кто что может
  - apiGroups: [rbac.authorization.k8s.io]
    resources: [roles, rolebindings, clusterroles, clusterrolebindings]
    verbs: [get, list, watch]
---
# -----------------------------------------------------------------------------
# Привилегированная роль службы ИБ: чтение ВСЕХ ресурсов, включая Secret;
# управление RBAC (выдача/отзыв прав только ролями propdev-*), сетевыми
# политиками и CSR пользователей; аудит. Нельзя менять рабочие нагрузки.
# -----------------------------------------------------------------------------
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: propdev-security-admin
  labels: { app.kubernetes.io/part-of: propdevelopment-rbac }
rules:
  - apiGroups: ["*"]
    resources: ["*"]
    verbs: [get, list, watch]                          # включая secrets
  - apiGroups: [rbac.authorization.k8s.io]
    resources: [roles, rolebindings, clusterrolebindings]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [rbac.authorization.k8s.io]
    resources: [clusterroles]
    verbs: [bind]                                      # связывать можно только с ролями компании
    resourceNames: [propdev-cluster-viewer, propdev-platform-operator,
                    propdev-ns-developer, propdev-ns-operations,
                    propdev-ns-secrets-manager]
  - apiGroups: [networking.k8s.io]
    resources: [networkpolicies]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [certificates.k8s.io]
    resources: [certificatesigningrequests]
    verbs: [get, list, watch, create, delete]
  - apiGroups: [certificates.k8s.io]
    resources: [certificatesigningrequests/approval]
    verbs: [update]
  - apiGroups: [certificates.k8s.io]
    resources: [signers]
    resourceNames: [kubernetes.io/kube-apiserver-client]
    verbs: [approve]
EOF

echo ">>> Роли уровня пространства имён (шаблоны для RoleBinding)"
cat <<'EOF' | kc apply -f -
# -----------------------------------------------------------------------------
# Разработчик домена: развёртывание и отладка сервисов в namespace своего домена.
# Нет доступа к Secret (секреты поставляются через Vault/DevOps), нет exec.
# -----------------------------------------------------------------------------
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: propdev-ns-developer
  labels: { app.kubernetes.io/part-of: propdevelopment-rbac }
rules:
  - apiGroups: [""]
    resources: [pods]
    verbs: [get, list, watch, delete]
  - apiGroups: [""]
    resources: [pods/log, events, endpoints, resourcequotas, limitranges]
    verbs: [get, list, watch]
  - apiGroups: [""]
    resources: [pods/portforward]
    verbs: [create]
  - apiGroups: [""]
    resources: [services, configmaps, persistentvolumeclaims]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [apps]
    resources: [deployments, statefulsets, replicasets, deployments/scale, statefulsets/scale]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [batch]
    resources: [jobs, cronjobs]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [autoscaling]
    resources: [horizontalpodautoscalers]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [networking.k8s.io]
    resources: [ingresses]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [networking.k8s.io]
    resources: [networkpolicies]
    verbs: [get, list, watch]
---
# -----------------------------------------------------------------------------
# Инженер по эксплуатации домена: мониторинг, логи, перезапуск подов,
# масштабирование. Не может менять конфигурацию сервисов и читать Secret.
# -----------------------------------------------------------------------------
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: propdev-ns-operations
  labels: { app.kubernetes.io/part-of: propdevelopment-rbac }
rules:
  - apiGroups: ["", apps, batch, autoscaling, policy, networking.k8s.io]
    resources: [pods, services, endpoints, configmaps, persistentvolumeclaims, events,
                deployments, statefulsets, replicasets, jobs, cronjobs,
                horizontalpodautoscalers, poddisruptionbudgets, ingresses, networkpolicies]
    verbs: [get, list, watch]
  - apiGroups: [""]
    resources: [pods/log]
    verbs: [get, list]
  - apiGroups: [""]
    resources: [pods]
    verbs: [delete]                                    # перезапуск зависшего пода
  - apiGroups: [apps]
    resources: [deployments/scale, statefulsets/scale]
    verbs: [get, update, patch]
  - apiGroups: [apps]
    resources: [deployments]
    verbs: [patch]                                     # kubectl rollout restart
---
# -----------------------------------------------------------------------------
# Привилегированная роль домена: управление Secret и ServiceAccount в namespace
# своего домена. Выдаётся только DevOps-инженеру продуктовой команды.
# -----------------------------------------------------------------------------
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: propdev-ns-secrets-manager
  labels: { app.kubernetes.io/part-of: propdevelopment-rbac }
rules:
  - apiGroups: [""]
    resources: [secrets, serviceaccounts]
    verbs: [get, list, watch, create, update, patch, delete]
EOF

echo
echo "Готово. Созданные роли:"
kc get clusterroles -l app.kubernetes.io/part-of=propdevelopment-rbac
