# After-Hours External Source

This project now supports an external after-hours data bridge for
`15:05-15:30` fixed-price trading.

## Default file

If this file exists, the after-hours report will load it automatically:

`data/after_hours_external.latest.json`

## File format

See:

`examples/after_hours_external.sample.json`

Required fields per item:

- `code`
- `supported`
- `volume`
- `amount`

Optional fields:

- `source`

## Import helper

You can copy any normalized external file into the default path with:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Import-AfterHoursExternalData.ps1 -SourcePath .\examples\after_hours_external.sample.json
```

## Report behavior

- External file present: prefer external after-hours data
- No external file: fall back to Eastmoney trends
- External item `supported = false`: show "数据源暂不支持盘后固定价格交易数据"
- External item `volume = 0` and `amount = 0`: show "无盘后成交"
