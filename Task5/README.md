# Задание 5. Управление трафиком внутри кластера Kubernetes

| Файл | Содержимое |
|---|---|
| `non-admin-api-allow.yaml` | Сетевые политики (NetworkPolicy) для namespace `default` |
| `deploy-and-test.sh` | Развёртывание четырёх сервисов nginx, применение политик и автоматическая проверка трафика |

## Модель изоляции

Используется подход «запрещено всё, что явно не разрешено»:

1. `default-deny-all` — запрещает весь входящий и исходящий трафик всех подов namespace.
2. `allow-dns-egress` — разрешает только DNS-запросы к `kube-dns`, чтобы работали имена сервисов.
3. `front-end-allow-back-end-api` + `back-end-api-allow-front-end` — двусторонний трафик (ingress и egress, TCP 80) только между `front-end` и `back-end-api`.
4. `admin-front-end-allow-admin-back-end-api` + `admin-back-end-api-allow-admin-front-end` — двусторонний трафик только между `admin-front-end` и `admin-back-end-api`.

Пользовательские и административные сервисы друг друга не видят. Любой новый под без разрешённой метки не может обратиться ни к одному из сервисов, и сам по себе тоже никуда не выходит, кроме DNS.

```
  front-end  <────>  back-end-api          admin-front-end  <────>  admin-back-end-api
       ╳                   ╳                       ╳                        ╳
       └──────── трафик между парами и от любых других подов запрещён ──────┘
```

## Запуск

Нужен CNI с поддержкой NetworkPolicy. В стандартном CNI Minikube политики не применяются, поэтому кластер запускается с Calico:

```bash
minikube start -p propdev --cni=calico

# сервисы
kubectl run front-end-app          --image=nginx --labels role=front-end          --expose --port 80
kubectl run back-end-api-app       --image=nginx --labels role=back-end-api       --expose --port 80
kubectl run admin-front-end-app    --image=nginx --labels role=admin-front-end    --expose --port 80
kubectl run admin-back-end-api-app --image=nginx --labels role=admin-back-end-api --expose --port 80

# политики
kubectl apply -f non-admin-api-allow.yaml

# ручная проверка: тестовый под с ролью front-end
kubectl run test-$RANDOM --rm -i -t --image=alpine --labels role=front-end -- sh
/ # wget -qO- --timeout=2 http://back-end-api-app         # ответ nginx — разрешено
/ # wget -qO- --timeout=2 http://admin-back-end-api-app   # timeout — запрещено
```

Тестовому поду нужно назначить метку роли (`--labels role=...`), чтобы проверить доступ от имени этого сервиса. Под без метки моделирует «любой другой под» — ему запрещено всё.

Автоматическая проверка всех сценариев: `./deploy-and-test.sh`

## Результат проверки (Minikube v1.39, Calico)

| Откуда (метка тестового пода) | Куда | Результат |
|---|---|---|
| front-end | back-end-api-app | разрешено ✅ |
| back-end-api | front-end-app | разрешено ✅ |
| admin-front-end | admin-back-end-api-app | разрешено ✅ |
| admin-back-end-api | admin-front-end-app | разрешено ✅ |
| front-end | admin-back-end-api-app | запрещено ⛔ |
| admin-front-end | back-end-api-app | запрещено ⛔ |
| back-end-api | admin-back-end-api-app | запрещено ⛔ |
| без метки | back-end-api-app | запрещено ⛔ |
| без метки | admin-back-end-api-app | запрещено ⛔ |
| без метки | front-end-app | запрещено ⛔ |

В продуктивной среде к этим правилам добавляется разрешение входящего трафика к `front-end` и `admin-front-end` от ingress-контроллера или API Gateway (namespace `platform`, см. Task3/Task4). Доступ к `admin-front-end` при этом ограничивается сетью сотрудников.
