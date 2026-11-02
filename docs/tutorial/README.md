# Уроки MacAutoDiag

Пошаговые уроки — от самого простого. Машина не нужна: всё делается на эмуляторе ЭБУ, который исполняет настоящую прошивку.

| Урок | О чём | Время |
|---|---|---|
| [1. Диагностика на эмуляторе](01-diagnostics-emulator.md) | запустить эмулятор, записать лог, двигать ползунки и смотреть, что меняется; напряжения на входах; откуда берутся ошибки; аварийный режим; ручное управление реле; снимок блока и обучение смеси | 40 мин |
| [2. Разбор лога](02-log-analysis.md) | открыть лог из урока 1, графики, метки, ячейки таблицы, коэффициент коррекции | 30 мин |
| [3. Разбор прошивки](03-firmware-analysis.md) | таблицы и их оси, карты УОЗ и смеси, кривые прогрева, константы, сравнение прошивок, перенос значений | 40 мин |
| [4. Чтение и запись блока](04-flash-emulator.md) | репетиция на эмуляторе: чтение, запись, отвязка иммобилайзера; что меняется на настоящем блоке | 25 мин |

Запуск приложения — из папки проекта:

```
tools/run-app.sh
```

Снимки в уроках сделаны скриптом `tools/tutorial-shot.sh` (его аргументы — те же ключи запуска, что упоминаются в уроках; ими же можно воспроизвести любой снимок). Снимки уроков 1, 2 и 4 обновлены 02.11.2026 (версия 0.11):

```
F=firmware/j5/j5v05l19/J5V05L19.BIN
tools/tutorial-shot.sh 01-open-firmware 12 $F --table t6AC8
tools/tutorial-shot.sh 02-diag-stopped 30 $F --diag
tools/tutorial-shot.sh 03-diag-engine 40 $F --diag --rpm 2500
tools/tutorial-shot.sh 04-recording 40 $F --diag --rpm 2500 --record
tools/tutorial-shot.sh 05-throttle-open 40 $F --diag --rpm 3000 --tps 2.5
tools/tutorial-shot.sh 06-cold-engine 40 $F --diag --rpm 1500 --clt -10
tools/tutorial-shot.sh 07-emergency-tps 40 $F --diag --rpm 1500 --tps 0
tools/tutorial-shot.sh 08-emergency-clt 40 $F --diag --rpm 1500 --clt -60
tools/tutorial-shot.sh 21-snapshot 45 $F --diag --snapshot
L=docs/tutorial/sample-log
tools/tutorial-shot.sh 12-log-cells 14 $F --log $L --logview cells
tools/tutorial-shot.sh 13-log-generic 20 --log $L --logview cells
tools/tutorial-shot.sh 22-flash-read-emulator 45 $F --flashread --flashread-start
tools/tutorial-shot.sh 24-flash-write-emulator 60 $F --flashwrite --flashwrite-go
tools/tutorial-shot.sh 25-flash-immo-emulator 25 $F --flashwrite --flashwrite-immo
```

Цифры в тексте — с этих снимков; в эмуляторе они немного зависят от того, сколько секунд прошло (регулятор ХХ, фильтры).

Для снимков графиков каналы задаются настройкой `logChartChannels`, а курсор — ключом `--charts-cursor <секунды>`: `tools/tutorial-shot.sh 11-log-charts 14 $F --log $L --logview charts --charts-cursor 80.2`. Снимок `23-flash-consent` делается с портом в настройке `diagnosticsSource` и ключом `--flashread-cable`. Снимки пишут логи и файлы в папку данных программы.
