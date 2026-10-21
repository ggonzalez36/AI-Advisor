# ADR 001: Implementación de Command Pattern y Worker Pool para Procesamiento Transaccional en Go

## Estado
Aprobado

## Fecha
2026-10-21

## Contexto del Negocio y Técnico
El backend transaccional de `fin-ai-advisor` (`portfolio-api`) requiere procesar flujos masivos de órdenes de compra y venta (`BuyOrder`, `SellOrder`) con baja latencia y alta concurrencia. En escenarios de alta volatilidad del mercado bursátil, miles de clientes envían operaciones de forma simultánea.

Los principales retos arquitectónicos identificados son:
1. **Agotamiento de Conexiones a Base de Datos (DB Starvation):** Crear una goroutine y una transacción PostgreSQL por cada solicitud entrante satura rápidamente el pool de conexiones (ej. `max_connections=100`), provocando timeouts y caídas en cascada.
2. **Consistencia Transaccional Distribuida (Saga Pattern):** Las transacciones financieras involucran múltiples subsistemas (validación de liquidez, reserva de capital, ejecución en el broker y liquidación contable). Si un paso falla, se requiere un mecanismo formal de compensación (`Undo`/Rollback).
3. **Desacoplamiento:** El emisor de la orden (controlador HTTP / consumidor gRPC) no debe conocer los detalles internos de ejecución ni retener bloqueos de red mientras la operación se procesa.

## Decisión Arquitectónica
Adoptamos el **Command Pattern** combinado con un **Worker Pool** gestionado por Goroutines y Channels en Go, conforme a los principios de diseño de [Refactoring.Guru: Command Pattern](https://refactoring.guru/design-patterns/command).

### 1. Command Pattern (`internal/domain/trade_command.go`)
- Definición de una interfaz canónica `Command`:
  ```go
  type Command interface {
      Execute(ctx context.Context) error
      Undo(ctx context.Context) error
      ID() string
  }
  ```
- Cada orden (ej. `BuyOrder`) encapsula todos los parámetros necesarios (ID, PortfolioID, Symbol, Quantity, Price, Timestamp) y su propia máquina de estados (`PENDING`, `EXECUTED`, `COMPENSATED`, `FAILED`).
- El método `Execute(ctx)` efectúa la mutación de estado y el débito de capital.
- El método `Undo(ctx)` ejecuta la transacción de compensación (reembolso y reversa de posición), permitiendo implementar el patrón Saga sin acoplamiento a frameworks externos.

### 2. Worker Pool Concurrente (`internal/engine/worker_pool.go`)
- Un pool de tamaño fijo de $N$ workers (goroutines) extrae comandos desde un canal con búfer (`buffered channel`).
- La ingesta de comandos utiliza semántica no bloqueante (`select` con cláusula `default`) o timeouts acotados para aplicar contrapresión (`backpressure`) en caso de saturación, respondiendo `HTTP 429 Too Many Requests` o encolando en dead-letter queue.
- El ciclo de vida de los workers se orquesta con `context.Context` y `sync.WaitGroup`, garantizando un drenado controlado (*graceful shutdown*) sin pérdida de órdenes en vuelo ni condiciones de carrera (*race-free*).

## Consecuencias y Compensaciones (Trade-offs)

### Positivas (+)
- **Protección de Recursos:** El número de transacciones concurrentes contra PostgreSQL está estrictamente acotado al tamaño del pool de workers ($N$), eliminando el riesgo de saturación de conexiones.
- **Tolerancia a Fallos y Reversibilidad:** La interfaz uniforme `Undo()` permite orquestar compensaciones automáticas inmediatas ante fallos en la ejecución de la orden.
- **Auditabilidad y Telemetría:** Cada comando posee un identificador único trazable de extremo a extremo, facilitando logs estructurados y métricas de latencia de ejecución.

### Negativas / Mitigaciones (-)
- **Memoria de Búfer:** Comandos retenidos en el canal consumen memoria volátil. *Mitigación:* Se define una capacidad máxima fija del canal y se rechazan/derivan excesos de carga cuando el canal alcanza el límite superior.
- **Complejidad de Compensación:** Los métodos `Undo()` deben ser idempotentes ante fallos repetidos de red. *Mitigación:* Se implementa verificación de estado atómica dentro de `Undo()`.

## Referencias
- Refactoring Guru: Command Design Pattern (<https://refactoring.guru/design-patterns/command>)
- Go Concurrency Patterns: Worker Pools (<https://go.dev/blog/pipelines>)
- Saga Pattern for Distributed Transactions
