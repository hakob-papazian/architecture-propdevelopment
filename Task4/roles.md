# Задание 4. Ролевая модель доступа к кластеру Kubernetes PropDevelopment

## Принципы

- **Минимальные привилегии.** Каждая группа получает только те действия, которые нужны для её работы. Просмотр секретов (`secrets`) — привилегированное действие: он есть только у службы ИБ, у DevOps-инженера в пространстве имён своего домена и у аварийной группы администраторов.
- **Разграничение по организационной структуре.** Каждому домену компании соответствует своё пространство имён (namespace). Права продуктовых команд действуют только в namespace их домена:

  | Домен | Namespace | Сервисы |
  |---|---|---|
  | Продажи | `sales` | витрина продаж, client-mart-app, client-tour-app, client-crm-app, client-mart-estate-app |
  | ЖКУ | `housing`, `smart-home` | tenant-core-app, CRM собственников; новые сервисы «Умный дом» из Task3 |
  | Финансы | `finance` | accountant-service-1 |
  | Дата | `data` | ETL/CDC, BI |
  | Платформа | `platform` | API Gateway, Keycloak, Vault, агенты мониторинга и SIEM |

- **Права выдаются группам, а не людям.** Группа задаётся полем `O` сертификата пользователя. В продуктивной среде её передаёт провайдер идентификации (OIDC через Keycloak/AD) в claim `groups`, поэтому при переводе или увольнении сотрудника права меняются в одном месте. Это закрывает проблему из Task2 (I.5, I.11–I.14).
- **Логи подов считаются конфиденциальными данными**: в них могут быть ПДн. Поэтому у роли только для просмотра нет доступа к `pods/log`.
- **Никто, кроме аварийной группы, не может выдать себе права.** Изменять RBAC может только служба ИБ, и только привязывая роли `propdev-*` (`bind` с `resourceNames`). Платформенная команда видит RBAC, но не изменяет его.

## Таблица ролей

| Роль | Права роли | Группы пользователей |
| --- | --- | --- |
| `cluster-admin` (встроенная ClusterRole, привязка `propdev-cluster-admins`) | Полный доступ ко всем ресурсам кластера. Используется только для аварийного доступа (break-glass): по заявке, с уведомлением ИБ и разбором журналов аудита после использования | `propdev:cluster-admins` — руководитель платформенной команды и его заместитель (1–2 человека) |
| `propdev-security-admin` (ClusterRole, привилегированная) | `get/list/watch` всех ресурсов во всех namespace, **включая `secrets`**. Управление `roles`, `rolebindings`, `clusterrolebindings`. `bind` только для ролей `propdev-*`. Управление `networkpolicies`. Выпуск и одобрение CSR пользователей. **Нельзя** изменять рабочие нагрузки | `propdev:security` — специалист по ИБ (и будущие сотрудники службы ИБ) |
| `propdev-platform-operator` (ClusterRole) | Настройка кластера: `nodes` (cordon/drain, метки, taints); полный доступ к `namespaces`, `persistentvolumes`, `storageclasses`, `resourcequotas`, `limitranges`, `priorityclasses`, `customresourcedefinitions`, admission-вебхукам и политикам, `ingresses`, `ingressclasses`, `networkpolicies`; рабочие нагрузки и `configmaps`, `services`, `serviceaccounts` во всех namespace; чтение `pods/log`, `events`, RBAC. **Нет** доступа к `secrets` (кроме namespace `platform`, см. ниже), к изменению RBAC и к `pods/exec` | `propdev:platform-ops` — платформенная команда (DevOps/SRE), которая сопровождает кластер |
| `propdev-cluster-viewer` (ClusterRole, только просмотр) | `get/list/watch` для рабочих нагрузок, сервисов, `configmaps`, `events`, `namespaces`, `nodes`, хранилищ, `ingresses`, `networkpolicies`, HPA, PDB, метрик. **Нет** доступа к `secrets`, `pods/log`, `pods/exec`, `pods/portforward`, нет действий на изменение | `propdev:viewers` — владельцы продуктов, бизнес-аналитики, аналитики BI, внутренние и внешние аудиторы. Дополнительно `propdev:platform-ops` |
| `propdev-ns-developer` (ClusterRole-шаблон, выдаётся через RoleBinding **только в namespace своего домена**) | Создание, изменение и удаление `deployments`, `statefulsets`, `jobs`, `cronjobs`, `services`, `configmaps`, `persistentvolumeclaims`, `ingresses`, HPA. Просмотр и удаление `pods`, чтение `pods/log`, `events`, `pods/portforward`. Чтение `networkpolicies`. **Нет** доступа к `secrets` и `pods/exec`, нет доступа к namespace других доменов | `propdev:sales-developers` → `sales`; `propdev:housing-developers` → `housing`, `smart-home`; `propdev:finance-developers` → `finance`; `propdev:data-developers` → `data`. Также DevOps-инженеры доменов (`propdev:<домен>-devops`) |
| `propdev-ns-operations` (ClusterRole-шаблон, RoleBinding в namespace домена) | Просмотр ресурсов namespace, чтение `pods/log`, удаление `pods` (перезапуск), масштабирование (`deployments/scale`, `statefulsets/scale`), `rollout restart`. **Нет** изменения конфигурации сервисов и доступа к `secrets` | `propdev:sales-operations`, `propdev:housing-operations`, `propdev:finance-operations`, `propdev:data-operations` — инженеры по эксплуатации продуктовых команд |
| `propdev-ns-secrets-manager` (ClusterRole-шаблон, привилегированная, RoleBinding в namespace домена) | Полное управление `secrets` и `serviceaccounts` **только в namespace своего домена** | `propdev:sales-devops`, `propdev:housing-devops`, `propdev:finance-devops`, `propdev:data-devops` — DevOps-инженер функциональной команды домена; `propdev:platform-ops` — только в namespace `platform` (TLS-сертификаты шлюза, конфигурация Keycloak и Vault) |

Операционные команды (менеджеры) с кластером не работают и доступа к нему не получают.

## Тестовые пользователи

| Пользователь | Группа | Должность | Что может |
|---|---|---|---|
| `anna.sokolova` | `propdev:viewers` | Бизнес-аналитик | Только просмотр ресурсов кластера |
| `boris.ivanov` | `propdev:platform-ops` | Инженер платформы | Настройка кластера, без секретов доменов |
| `elena.smirnova` | `propdev:security` | Специалист по ИБ | Просмотр секретов, управление RBAC |
| `dmitry.kozlov` | `propdev:sales-developers` | Разработчик домена «Продажи» | Развёртывание сервисов в `sales` |
| `olga.novikova` | `propdev:housing-devops` | DevOps-инженер домена «ЖКУ» | Развёртывание и секреты в `housing`, `smart-home` |
| `pavel.orlov` | `propdev:finance-operations` | Инженер по эксплуатации «Финансы» | Логи, перезапуск и масштабирование в `finance` |

## Скрипты

| Файл | Пункт задания | Что делает |
|---|---|---|
| `01-create-users.sh` | 3. Создание пользователей | Генерирует ключ и CSR (`CN` = пользователь, `O` = группа), выпускает сертификат через Kubernetes CSR API (срок жизни 30 дней), добавляет пользователя и контекст в kubeconfig |
| `02-create-roles.sh` | 4. Создание ролей | Создаёт namespace доменов и все ClusterRole из таблицы |
| `03-bind-roles.sh` | 5. Связывание пользователей с ролями | Создаёт ClusterRoleBinding и RoleBinding для групп и проверяет права через `kubectl auth can-i` (24 проверки) |

Запуск на пустом Minikube (Linux/macOS или Git Bash на Windows):

```bash
minikube start -p propdev
export KUBE_CONTEXT=propdev
./01-create-users.sh
./02-create-roles.sh
./03-bind-roles.sh

# работа от имени пользователя
kubectl --context dmitry.kozlov@propdev -n sales get pods      # разрешено
kubectl --context dmitry.kozlov@propdev -n housing get pods    # Forbidden
kubectl --context anna.sokolova@propdev -n sales get secrets   # Forbidden
```

Ключи и сертификаты пользователей сохраняются в `Task4/users/`. Этот каталог исключён из Git.

## Известные ограничения и компенсирующие меры

- Тот, кто может создавать поды в namespace, теоретически может примонтировать в под любой секрет этого namespace. Поэтому у `propdev-platform-operator` нет доступа к `pods/exec`, а в namespace включены Pod Security Admission (`baseline` и `restricted`). Дополнительно рекомендуется admission-политика (Kyverno или ValidatingAdmissionPolicy), которая запрещает монтировать секреты из чужих сервисов, и журнал аудита API-сервера с отправкой в SIEM.
- В продуктивной среде вместо клиентских сертификатов нужно использовать OIDC (Keycloak, MFA). Клиентский сертификат Kubernetes нельзя отозвать до окончания его срока, поэтому срок ограничен 30 днями.
