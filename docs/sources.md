# Источники


## Документация

| Что | Где | Использовано для |
|---|---|---|
| Протокол KWP2000 M1.5.4N / Январь-5 (SMS-Soft) | https://almisoft.ru/files/kwp2000_euro2.rar | кадр `21 01`, формулы, флаги, коды ошибок → `kwp2000-j5.md` |
| Серийные прошивки J5 / J7.2 | https://chiptuner.ru/content/ser_j5/, `/ser_j72/` | `firmware/j5`, `firmware/j72`, опубликованные КС |
| C509 / M509 (datasheet) | `cmgt/j7es` → `info/m509.pdf`, `info/c500_aism.pdf` | эмулятор процессора |

## Открытый код и разметка 

| Репозиторий | Что внутри | Значение для проекта |
|---|---|---|
| [cmgt/ecusystems](https://github.com/cmgt/ecusystems) | OpenOLT, парсер карт ChipTuningPRO (`CtpMaps`), `map2xdf`, `i205do54.xdf`, `RpmQuantRecalc`, `KWPTest` | формат карт CTP `.j5/.j7` → импорт описаний таблиц |
| [cmgt/j7esa](https://github.com/cmgt/j7esa) | исходник спортивной прошивки J7.2 на ассемблере, прокомментированная область калибровок с `0x5ED0` | справочник назначений калибровок (для J7.2; в J5 адреса другие) |
| [cmgt/dm_bir_olt](https://github.com/cmgt/dm_bir_olt) | базы IDA для I205DM53 и **J5LS_V46**, карты CTP **`j5ls_v43.j5`**, `j5ls_v46.j5`, `J5LS_V46_part1.asm`, `ram_map.txt`, `address_map.txt` | есть готовая карта под J5LS V43 |
| [cmgt/j7es](https://github.com/cmgt/j7es) | документация C509/M509, фото платы Январь 5, редактор карт на Delphi | эмулятор |
| [ra6fho/JEcu](https://github.com/ra6fho/JEcu) | диагностика Январь 5.1 по K-line на Java | сверка протокола |
| [rusefi_documentation/OEM-Docs/January_7.2](https://github.com/rusefi/rusefi_documentation/tree/master/OEM-Docs/January_7.2) | схемы и фото плат | стенд, распиновка |

## Сайт автора J5LS

http://rotorman.dtt-motorsport.ru/j5-sport/ (только http). Главное:

| Документ | Файл | Что |
|---|---|---|
| Инструкция J5LS V43B…E (26.11.2020) | `j5ls_v43b.rar` | совместимость адресов с V43, список отличий от серийного ПО |
| Дополнение протокола диагностики для J5LS (16.10.2020) | `prot.xls` | запросы `21 8C/0D/0F`, расширенный кадр |
| Распиновка Январь-5.1 под J5LS_V43 | `j5pinout_v43.htm` | |
| Ускорение KWP в поздних V43 | `ecucheck.htm` | скорость 62500 бод |

Сводка — `j5ls.md`.

Защита J5LS здесь не описывается. Предупреждение для владельца — в `j5ls.md`.
