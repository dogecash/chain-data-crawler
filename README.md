# chain-data-crawler.sh

This crawler push data from block chain in to influxDb, we use this in production to provide maximum project transparency.
This data can be used for API or any sort of analysis.

Result of this work can be observed at https://chain.dogec.io

This script have chaos engineering in core, mean he will take care of crashes, accidentally server restarts or any sort of issues.
Script will self recover, check latest data in database, check latest chain height and maintain perfect synchronization in any circumstances.

However, validators data state is not stored on protocol level and can't be queried from the past, this data only exits from the moment crawling process started and will not present at the frame where crawling process stopped.

For complete functionality script should be run by systemd with `Restart=Always` and reasonable delays.

* example:

```
[Unit]
Description=Chain Data Crawler
After=network.target

[Service]
User=user9099
Group=user9099
Type=simple
ExecStart=/home/user9099/chain-data-crawler.sh

Restart=always
RestartSec=20s
TimeoutStartSec=120s

LogLevelMax=3

[Install]
WantedBy=multi-user.target
```

_Chain daemon should be perfectly maintained and sync with chain in atomic precission. This part is not covered here._


