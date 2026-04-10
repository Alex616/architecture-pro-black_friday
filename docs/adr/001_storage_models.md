# 001 Схема данных

## Описание

Онлайн-магазин «Мобильный мир» сильно вырос, и теперь там можно купить не только аксессуары для смартфонов, но также электронику, аудио- и бытовую технику и другие категории товаров. Однако бэкенд сайта всё так же состоит из нескольких микросервисов. Нужно расписать коллекции для хранения данных.

## Колекции

### Коллекция orders — заказы клиентов

**Назначение**: хранение информации о заказах пользователей с полной детализацией состава и статуса.

**Ключевые особенности**:

- Денормализация данных о товарах (хранение title, category, price в момент заказа)
- Поддержка отслеживания изменений через created_at/updated_at
- Привязка к географической позиции для шардирования

#### Схема коллекции

| Поле           | Тип       | Описание                                                  |
| -------------- | --------- | --------------------------------------------------------- |
| `id`           | uuid      | Уникальный идентификатор заказа                           |
| `user_id`      | uuid      | Идентификатор пользователя-покупателя                     |
| `created_at`   | timestamp | Дата и время создания заказа                              |
| `updated_at`   | timestamp | Дата и время последнего изменения                         |
| `items`        | array     | Список позиций в заказе (см. структуру ниже)              |
| `status`       | enum      | Статус: `pending`, `processing`, `completed`, `cancelled` |
| `total_money`  | float     | Общая сумма заказа в рублях                               |
| `geo_position` | int       | ID географического региона (ключ шардирования)            |

**Структура элемента items**:

```
┌─ item ─────────────────────┐
│ product_id   uuid           │ → Ссылка на products.id
│ title        string         │ ← Снимок названия на момент заказа
│ category     string         │ ← Снимок категории на момент заказа
│ price        float          │ ← Цена на момент заказа
│ quantity     int            │   Количество единиц товара
└─────────────────────────────┘
```

#### Создание коллекции

```javascript
db.createCollection("orders", {
  validator: {
    $jsonSchema: {
      bsonType: "object",
      required: [
        "id",
        "user_id",
        "created_at",
        "updated_at",
        "items",
        "status",
        "total_money",
        "geo_position",
      ],
      properties: {
        id: {
          bsonType: "string",
          description: "Уникальный идентификатор заказа (UUID)",
        },
        user_id: {
          bsonType: "string",
          description: "Идентификатор пользователя (UUID)",
        },
        created_at: {
          bsonType: "date",
          description: "Дата и время создания заказа",
        },
        updated_at: {
          bsonType: "date",
          description: "Дата и время последнего обновления заказа",
        },
        items: {
          bsonType: "array",
          description: "Список товаров в заказе",
          items: {
            bsonType: "object",
            required: ["product_id", "title", "category", "price", "quantity"],
            properties: {
              product_id: { bsonType: "string" },
              title: { bsonType: "string" },
              category: { bsonType: "string" },
              price: { bsonType: "double" },
              quantity: { bsonType: "int" },
            },
          },
        },
        status: {
          bsonType: "string",
          enum: ["pending", "processing", "completed", "cancelled"],
          description: "Статус заказа",
        },
        total_money: {
          bsonType: "double",
          description: "Общая стоимость заказа",
        },
        geo_position: {
          bsonType: "int",
          description: "Геопозиция клиента",
        },
      },
    },
  },
});
```

#### Стратегия шардирования

**Шардирующий ключ**: `{geo_position: 1, id: 1}` (Range-based sharding)

**Обоснование выбора**:

**Плюсы**:

- **Географическая локальность заказов**: заказы из одного региона физически расположены рядом, что упрощает региональную аналитику
- **Региональная аналитика**: отчёты по регионам выполняются локально без cross-shard запросов
- **Естественная группировка**: заказы из одного региона физически расположены рядом

**Минусы**:

- **Cross-shard транзакция с products**: при создании заказа требуется обновить `products.geo_amounts[N].amount` (шард по `category`) и создать документ в `orders` (шард по `geo_position`)
  - _Решение_: использовать distributed transaction с изоляцией snapshot
  - _Альтернатива_: event sourcing с eventual consistency (не рекомендуется для критичных операций)
- **Cross-shard при поиске истории пользователя**: запрос `{user_id}` может затронуть несколько шардов, если пользователь заказывал из разных регионов
  - _Решение_: денормализация — хранить в User Service последний geo_position пользователя и запрашивать `{user_id, geo_position}`
  - _Альтернатива_: scatter-gather запрос по всем шардам (приемлемо для истории заказов)
- **Неравномерность распределения**: крупные города (Москва) vs маленькие регионы
  - _Решение_: zone sharding — выделить отдельные зоны для крупных регионов

**Почему именно эта стратегия**:
При создании заказа происходит одновременное обновление остатков товаров. Использование geo_position как ключа шардирования обеспечивает, что заказ и соответствующие товары находятся в одном шарде, что критично для производительности и консистентности данных.

**Создание шардирования**:

```javascript
// 1. Создать индекс для шардирующего ключа
db.orders.createIndex({ geo_position: 1, id: 1 }, { name: "shard_key_orders" });

// 2. Включить шардирование для базы данных (если ещё не включено)
sh.enableSharding("shop");

// 3. Шардировать коллекцию
sh.shardCollection("shop.orders", { geo_position: 1, id: 1 });

// 4. (Опционально) Настроить zone sharding для крупных регионов
sh.addShardTag("shard01", "moscow_zone");
sh.addShardTag("shard02", "moscow_zone");
sh.addTagRange(
  "shop.orders",
  { geo_position: 77, id: MinKey },
  { geo_position: 77, id: MaxKey },
  "moscow_zone",
);
```

#### Индексы

**Обоснование выбора индексов**:

- `id` — первичный ключ для прямого доступа к заказу
- `geo_position + id` — шардирующий ключ
- `geo_position + user_id` — поиск заказов пользователя в конкретном регионе
- `geo_position + status` — фильтрация заказов по статусу внутри региона

```javascript
// Уникальный индекс на id заказа
db.orders.createIndex({ id: 1 }, { unique: true, name: "idx_orders_id" });

// Шардирующий ключ (составной индекс)
db.orders.createIndex({ geo_position: 1, id: 1 }, { name: "shard_key_orders" });

// Индекс для поиска заказов пользователя в регионе
db.orders.createIndex(
  { geo_position: 1, user_id: 1 },
  { name: "idx_orders_geo_user" },
);

// Индекс для фильтрации по статусу внутри региона
db.orders.createIndex(
  { geo_position: 1, status: 1 },
  { name: "idx_orders_geo_status" },
);
```

---

### Коллекция products — каталог товаров

**Назначение**: хранение актуальной информации о товарах в каталоге интернет-магазина.

**Ключевые особенности**:

- Гибкая схема атрибутов через поле `attributes` (позволяет добавлять специфичные для категории поля)
- Контроль остатков через поле `amount`
- Географическое распределение по складам

#### Схема коллекции

| Поле          | Тип    | Описание                                                   |
| ------------- | ------ | ---------------------------------------------------------- |
| `id`          | uuid   | Уникальный идентификатор товара                            |
| `title`       | string | Название товара                                            |
| `category`    | string | Категория (электроника, аудио, бытовая техника и т.д.)     |
| `price`       | float  | Актуальная цена в рублях                                   |
| `geo_amounts` | array  | Список остатков по регионам (см. структуру ниже)           |
| `attributes`  | map    | Динамические атрибуты (цвет, размер, вес, мощность и т.д.) |

**Структура элемента geo_amounts**:

```
┌─ geo_amount ────────────────┐
│ geo_position   int          │   ID склада/региона
│ amount         int          │   Количество единиц на складе
└──────────────────────────────┘
```

**Пример документа**:

```javascript
{
  id: "550e8400-e29b-41d4-a716-446655440000",
  title: "iPhone 15 Pro 256GB",
  category: "smartphones",
  price: 89990.00,
  geo_amounts: [
    { geo_position: 77, amount: 50 },  // Москва
    { geo_position: 78, amount: 30 },  // Санкт-Петербург
    { geo_position: 23, amount: 20 }   // Краснодар
  ],
  attributes: {
    color: "черный",
    memory: "256GB",
    screen_size: "6.1\""
  }
}
```

**Примеры attributes для разных категорий**:

```javascript
// Смартфон
{ "color": "черный", "memory": "128GB", "screen_size": "6.1\"" }

// Наушники
{ "type": "накладные", "wireless": true, "battery_hours": 40 }

// Холодильник
{ "volume_liters": 350, "energy_class": "A++", "freezer": true }
```

#### Создание коллекции

```javascript
db.createCollection("products", {
  validator: {
    $jsonSchema: {
      bsonType: "object",
      required: [
        "id",
        "title",
        "category",
        "price",
        "geo_amounts",
        "attributes",
      ],
      properties: {
        id: {
          bsonType: "string",
          description: "Уникальный идентификатор товара (UUID)",
        },
        title: {
          bsonType: "string",
          description: "Название товара",
        },
        category: {
          bsonType: "string",
          description: "Категория товара",
        },
        price: {
          bsonType: "double",
          description: "Цена товара",
        },
        geo_amounts: {
          bsonType: "array",
          description: "Список остатков товара по регионам",
          items: {
            bsonType: "object",
            required: ["geo_position", "amount"],
            properties: {
              geo_position: {
                bsonType: "int",
                description: "ID склада/региона",
              },
              amount: {
                bsonType: "int",
                description: "Количество единиц на складе в этом регионе",
              },
            },
          },
        },
        attributes: {
          bsonType: "object",
          description:
            "Гибкая карта атрибутов товара (цвет, вес, размеры и т.д.)",
          additionalProperties: true,
        },
      },
    },
  },
});
```

#### Стратегия шардирования

**Шардирующий ключ**: `{category: 1, id: 1}` (Range-based sharding)

**Обоснование выбора**:

**Плюсы**:

- **Глобальный поиск по категории**: запрос товаров по категории выполняется без cross-shard операций
- **Равномерное распределение**: товары разных категорий распределены по шардам, что снижает риск hotspots
- **Упрощение глобального каталога**: пользователи видят товары всех регионов в одной категории одним запросом
- **Централизованное обновление**: изменение цены или атрибутов товара требует обновления только одного документа

**Минусы**:

- **Cross-shard транзакции при создании заказа**: при создании заказа в регионе N нужно:
  1. Прочитать `products` (шард по `category`)
  2. Обновить `geo_amounts[N].amount` в `products`
  3. Создать документ в `orders` (шард по `geo_position`)
  - Эти операции происходят в разных шардах, требуется распределенная транзакция
  - также есть задержка выполнения запроса
- **Конкуренция за популярные товары**: обновление `geo_amounts` в одном документе создаёт write contention при высокой нагрузке
- **Потенциальный дисбаланс**: популярные категории (например, "Электроника") могут создать hotspot на одном шарде

**Почему именно эта стратегия**:
На начальном этапе развития бизнеса приоритет — удобство работы с каталогом и упрощение поиска товаров по категориям. Пользователи должны видеть все доступные товары независимо от региона. Cross-shard транзакции при создании заказа являются приемлемыми на данном этапе.

**Создание шардирования**:

```javascript
// 1. Создать индекс для шардирующего ключа
db.products.createIndex({ category: 1, id: 1 }, { name: "shard_key_products" });

// 2. Включить шардирование для базы данных (если ещё не включено)
sh.enableSharding("shop");

// 3. Шардировать коллекцию
sh.shardCollection("shop.products", { category: 1, id: 1 });

// 4. (Опционально) Настроить pre-splitting для популярных категорий
sh.splitAt("shop.products", { category: "smartphones", id: MinKey });
sh.splitAt("shop.products", { category: "laptops", id: MinKey });
sh.splitAt("shop.products", { category: "audio", id: MinKey });
```

#### Индексы

**Обоснование выбора индексов**:

- `id` — первичный ключ для прямого доступа к товару
- `category + id` — шардирующий ключ
- `category + price` — поиск и сортировка товаров в категории по цене

```javascript
// Уникальный индекс на id товара
db.products.createIndex({ id: 1 }, { unique: true, name: "idx_products_id" });

// Шардирующий ключ (составной индекс)
db.products.createIndex({ category: 1, id: 1 }, { name: "shard_key_products" });

// Индекс для поиска товаров в категории с сортировкой по цене
db.products.createIndex(
  { category: 1, price: 1 },
  { name: "idx_products_category_price" },
);
```

---

### Коллекция carts — корзины покупателей

**Назначение**: хранение временных корзин как для авторизованных пользователей, так и для гостей.

**Ключевые особенности**:

- Поддержка гостевых корзин через `session_id` (без авторизации)
- Автоматическое удаление через TTL индекс по `expires_at`
- Отслеживание жизненного цикла корзины через статусы

#### Схема коллекции

| Поле                 | Тип       | Описание                                                   |
| -------------------- | --------- | ---------------------------------------------------------- |
| `id`                 | uuid      | Уникальный идентификатор корзины                           |
| `user_id`            | uuid?     | Идентификатор пользователя (null для гостей)               |
| `session_id`         | uuid?     | Идентификатор сессии для гостевых корзин                   |
| `user_id_or_session` | string    | Композитное поле для шардирования (user_id или session_id) |
| `items`              | array     | Список товаров в корзине (см. структуру ниже)              |
| `status`             | enum      | Статус: `active`, `ordered`, `abandoned`                   |
| `created_at`         | timestamp | Дата и время создания корзины                              |
| `updated_at`         | timestamp | Дата и время последнего изменения                          |
| `expires_at`         | timestamp | Срок автоматического удаления корзины                      |

**Структура элемента items**:

```
┌─ item ─────────────────────┐
│ product_id   uuid           │ → Ссылка на products.id
│ quantity     int            │   Количество единиц товара
└─────────────────────────────┘
```

**Логика работы с пользователями**:

- **Авторизованный пользователь**: `user_id` заполнен, `session_id` = null, `user_id_or_session` = user_id
- **Гостевая корзина**: `user_id` = null, `session_id` заполнен, `user_id_or_session` = session_id
- При авторизации гостя: происходит слияние гостевой и пользовательской корзин с обновлением `user_id_or_session`

#### Создание коллекции

```javascript
db.createCollection("carts", {
  validator: {
    $jsonSchema: {
      bsonType: "object",
      required: [
        "id",
        "user_id_or_session",
        "items",
        "status",
        "created_at",
        "updated_at",
        "expires_at",
      ],
      properties: {
        id: {
          bsonType: "string",
          description: "Уникальный идентификатор корзины (UUID)",
        },
        user_id: {
          bsonType: ["string", "null"],
          description:
            "Идентификатор пользователя (UUID), null для гостевых корзин",
        },
        session_id: {
          bsonType: ["string", "null"],
          description: "Идентификатор сессии для гостевых корзин (UUID)",
        },
        user_id_or_session: {
          bsonType: "string",
          description:
            "Композитное поле для шардирования: user_id для авторизованных, session_id для гостей",
        },
        items: {
          bsonType: "array",
          description: "Список товаров в корзине",
          items: {
            bsonType: "object",
            required: ["product_id", "quantity"],
            properties: {
              product_id: { bsonType: "string" },
              quantity: { bsonType: "int" },
            },
          },
        },
        status: {
          bsonType: "string",
          enum: ["active", "ordered", "abandoned"],
          description: "Статус корзины",
        },
        created_at: {
          bsonType: "date",
          description: "Дата и время создания корзины",
        },
        updated_at: {
          bsonType: "date",
          description: "Дата и время последнего обновления",
        },
        expires_at: {
          bsonType: "date",
          description: "Дата и время истечения корзины",
        },
      },
    },
  },
});
```

#### Стратегия шардирования

**Шардирующий ключ**: `{user_id_or_session: "hashed"}` (Hashed sharding)

**Обоснование выбора**:

**Плюсы**:

- **Идеальная равномерность распределения**: хеширование UUID гарантирует равномерное распределение нагрузки между шардами
- **Защита от hotspots**: даже VIP пользователи с высокой активностью распределены случайно по шардам
- **Простота схемы**: всё в MongoDB, нет необходимости в дополнительных системах (Redis)
- **Производительность RMW операций**: все операции Read-Modify-Write с одной корзиной выполняются локально в одном шарде
- **Унификация гостей и пользователей**: одно поле `user_id_or_session` для обоих типов корзин

**Минусы**:

- **Cross-shard операция при слиянии корзин**: при авторизации гостя требуется координация между шардами (гостевая корзина в шарде A, пользовательская в шарде B)
  - _Частота_: редкая операция (пользователь авторизуется 1 раз)
  - _Задержка_: ~50-100ms дополнительно (приемлемо для процесса авторизации)
- **Дополнительное поле**: +4-36 байт на документ (~1-2% размера коллекции)

**Почему именно эта стратегия**:
Корзины имеют очень высокую частоту обновлений (добавление/удаление товаров при каждом клике). Hashed sharding обеспечивает равномерное распределение нагрузки и гарантирует отсутствие горячих точек даже при наличии очень активных пользователей.

**Логика слияния при авторизации**:
При авторизации гостя выполняется cross-shard транзакция:

1. Читается гостевая корзина (`user_id_or_session = session_id`)
2. Читается или создаётся пользовательская корзина (`user_id_or_session = user_id`)
3. Товары объединяются (с дедупликацией по product_id)
4. Пользовательская корзина обновляется
5. Гостевая корзина помечается как `abandoned`

**Создание шардирования**:

```javascript
// 1. Создать hashed индекс для шардирующего ключа
db.carts.createIndex(
  { user_id_or_session: "hashed" },
  { name: "shard_key_carts" },
);

// 2. Включить шардирование для базы данных (если ещё не включено)
sh.enableSharding("shop");

// 3. Шардировать коллекцию с hashed стратегией
sh.shardCollection("shop.carts", { user_id_or_session: "hashed" });
```

#### Индексы

**Обоснование выбора индексов**:

- `id` — первичный ключ для прямого доступа к корзине
- `user_id_or_session` (hashed) — шардирующий ключ
- `user_id_or_session + status` — поиск активной корзины пользователя/гостя
- `expires_at` (TTL) — автоматическая очистка заброшенных корзин

```javascript
// Уникальный индекс на id корзины
db.carts.createIndex({ id: 1 }, { unique: true, name: "idx_carts_id" });

// Шардирующий ключ (hashed индекс)
db.carts.createIndex(
  { user_id_or_session: "hashed" },
  { name: "shard_key_carts" },
);

// Индекс для поиска активной корзины пользователя/гостя
db.carts.createIndex(
  { user_id_or_session: 1, status: 1 },
  { name: "idx_carts_user_or_session_status" },
);

// TTL индекс для автоматического удаления заброшенных корзин
db.carts.createIndex(
  { expires_at: 1 },
  {
    expireAfterSeconds: 0,
    partialFilterExpression: { status: "abandoned" },
    name: "idx_carts_ttl",
  },
);
```
