# ADR 003: Persistencia Transaccional con Outbox, Ledger Append-Only y SQLite

## Estado
Aprobado

## Fecha
2026-10-21

## Contexto
El Worker Pool de [ADR 001](001-command-worker-pool-go.md) encolaba órdenes únicamente en memoria. Esto dejaba tres problemas abiertos:

1. **Durabilidad:** si el proceso caía entre aceptar la orden (HTTP 202) y ejecutarla, la orden se perdía sin rastro.
2. **Reintentos del cliente:** un timeout de red hacía que el cliente reenviara la orden y se ejecutara dos veces (doble cargo).
3. **Representación monetaria:** los montos viajaban como `float64`, con errores de redondeo inaceptables en finanzas (`0.1 + 0.2 != 0.3`).

## Decisión

### 1. Transactional Outbox
`POST /orders/buy` inserta la orden (`PENDING`) **y** un evento `OrderAccepted` en la tabla `outbox` dentro de **una sola transacción**. Después intenta despachar al Worker Pool (camino rápido). Un **relay** periódico re-despacha los eventos que siguen sin publicar (pool saturado o caída del proceso).

- Entrega **at-least-once**: una orden puede llegar dos veces al pool (camino rápido + relay).
- Ejecución **at-most-once**: el worker reclama la orden con un compare-and-set `UPDATE orders SET status='EXECUTING' WHERE id=? AND status='PENDING'`. Solo un worker obtiene `RowsAffected = 1`; los demás descartan la entrega como duplicada.

### 2. Idempotency-Key
El cliente envía el header `Idempotency-Key`. La columna `orders.idempotency_key` es `UNIQUE`: un reintento devuelve la orden original (HTTP 200) en vez de crear otra.

### 3. Ledger append-only
Los movimientos (`CASH_DEBIT`, `POSITION_CREDIT`, `FUNDS_RESERVED`, `FUNDS_RELEASED`) se insertan en `ledger_entries` y **nunca se modifican**: hay triggers que abortan cualquier `UPDATE` o `DELETE`. Las posiciones se derivan con `SUM(amount) GROUP BY asset`.

- Evita bloquear una fila de "saldo" compartida en cada escritura (write-lock contention).
- Deja una auditoría completa. La compensación Saga se registra como un asiento inverso, no como un borrado.

### 4. Dinero en enteros
Precios en centavos (`INTEGER`) y cantidades en acciones enteras. La API recibe los precios como texto decimal (`"185.50"`) y los convierte sin pasar por `float`.

### 5. Decorator para persistencia
`orders.persistentOrder` implementa `domain.Command` envolviendo a `domain.BuyOrder`. El dominio sigue siendo puro (sin SQL) y el Worker Pool no distingue entre ambos.

### 6. SQLite (driver `modernc.org/sqlite`, Go puro)
- No requiere cgo ni contenedores: el proyecto corre y se prueba con `go test` en cualquier máquina y en CI.
- Modo WAL + `busy_timeout` + `_txlock=immediate` para manejar la concurrencia de un único escritor.
- Todo el SQL vive en `internal/store` detrás de interfaces (`orders.Repository`, `httpapi.Reader`).

## Consecuencias

### Positivas (+)
- Ninguna orden aceptada se pierde ante una caída; los reintentos son seguros.
- Las invariantes se refuerzan en la BD (`CHECK`, `UNIQUE`, triggers), no solo en el código.
- Tests de integración reales (BD temporal por test) sin dependencias externas.

### Negativas / Mitigaciones (-)
- **SQLite tiene un solo escritor:** limita el throughput de escritura. *Mitigación:* en producción se usa PostgreSQL (RDS, ya provisionado en `infra/`). Solo cambia el paquete `store`: `SELECT ... FOR UPDATE SKIP LOCKED` en el relay, `NUMERIC(20,4)` o `BIGINT` para montos y un pool de conexiones mayor.
- **Latencia del relay:** una orden diferida espera hasta `relayInterval + relayMinAge` (~7 s). Es aceptable porque la API ya es asíncrona (202 + polling de `GET /orders/{id}`).
- **Fallo al persistir tras ejecutar en el broker:** la orden queda en `EXECUTING`. *Mitigación pendiente:* un job de reconciliación que consulte al broker para las órdenes `EXECUTING` más antiguas que N minutos.

## Alternativas consideradas
- **Publicar directo a Kafka/SQS desde el handler:** sufre el problema de *dual write* (la BD confirma y el broker falla, o al revés). El outbox lo resuelve con una sola transacción local.
- **Fila de saldo con `UPDATE balance = balance - x`:** es más simple, pero serializa las escrituras por portafolio y pierde el historial.
- **PostgreSQL desde el día 1:** es el destino de producción, pero exige Docker para desarrollo y CI. Para el alcance actual, SQLite maximiza la reproducibilidad.
