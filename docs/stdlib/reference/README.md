# Standard Library Reference Corpus

This directory stores local reference material for externally defined optional
standard libraries implemented by Consent Scheme's stdlib layer.

The `srfi-*` directories contain untouched HTML snapshots from
`https://srfi.schemers.org/`. They are vendored as reference documents, not as
authored Consent Scheme documentation. Licensing for these third-party HTML
snapshots is recorded in the root `REUSE.toml`.

The `r7rs-large` directory contains R7RS-large ballot and edition snapshots
from the official `scheme/r7rs` Codeberg repository. Those reports are vendored
as reference documents under the report-copying permission recorded in
`r7rs-large/LICENCE.txt` and in `LICENSES/LicenseRef-R7RS-Report-Permission.txt`.

## Snapshot Inventory

| Reference | Local path | Upstream URL | SHA-256 |
| --- | --- | --- | --- |
| SRFI 0 | `srfi-0/srfi-0.html` | `https://srfi.schemers.org/srfi-0/srfi-0.html` | `2a831d143df6d73ea10f2ab1323c7340f0964c21d55d95f34a323bc89a7144eb` |
| SRFI 1 | `srfi-1/srfi-1.html` | `https://srfi.schemers.org/srfi-1/srfi-1.html` | `db1bdaff7f13b25f5f16426481463867ce269e30fdf5586b04b75581f53aafd8` |
| SRFI 2 | `srfi-2/srfi-2.html` | `https://srfi.schemers.org/srfi-2/srfi-2.html` | `04d8485a010d6d2149294b2da91c10a1b85bdf4014426b4e9db6809d5f4b232f` |
| SRFI 8 | `srfi-8/srfi-8.html` | `https://srfi.schemers.org/srfi-8/srfi-8.html` | `745e473cbe3062150587b9e9412603caa53b452c1dd6648f3e3cdaad8eff33eb` |
| SRFI 16 | `srfi-16/srfi-16.html` | `https://srfi.schemers.org/srfi-16/srfi-16.html` | `a2a16ebe3811e36a12a4eee69665ba739bdd88f67d04563f4ad80ca35c590fbd` |
| SRFI 27 | `srfi-27/srfi-27.html` | `https://srfi.schemers.org/srfi-27/srfi-27.html` | `505040519b7d44a26152e424d932dec72dbb53eee153314189f9cc15bb88ac8e` |
| SRFI 64 | `srfi-64/srfi-64.html` | `https://srfi.schemers.org/srfi-64/srfi-64.html` | `ad4b7ab6c2137c997e21d3a0c2a347ee99f2837ad79467200d0b63bff8cfb1a5` |
| SRFI 97 | `srfi-97/srfi-97.html` | `https://srfi.schemers.org/srfi-97/srfi-97.html` | `a0572a9fd50bead52d86ffa1a589f00e013a0ad0842a837026d076134b3bfb43` |
| SRFI 128 | `srfi-128/srfi-128.html` | `https://srfi.schemers.org/srfi-128/srfi-128.html` | `e981d747fc5f53bcc72f6868333a35cf056b198386b80541a2ff266916c9fa97` |
| SRFI 145 | `srfi-145/srfi-145.html` | `https://srfi.schemers.org/srfi-145/srfi-145.html` | `fb1478fcc3060bc39005a521dfae8743a080ed72dcdc72c9fc61df6077667fa6` |
| SRFI 146 | `srfi-146/srfi-146.html` | `https://srfi.schemers.org/srfi-146/srfi-146.html` | `70ed5d8e30f7eb4d8bfdbf56e51943ee1dfaf1404392e175551819531fc9eab0` |
| SRFI 158 | `srfi-158/srfi-158.html` | `https://srfi.schemers.org/srfi-158/srfi-158.html` | `c4bb02803ddf8000e93ac9ab766bc0a1cd86cc8810e55ae87e8b5aa593802b69` |
| SRFI 180 | `srfi-180/srfi-180.html` | `https://srfi.schemers.org/srfi-180/srfi-180.html` | `a92f2442382c1074895814385ef5314f62ae85e698d93ffad840f92dbfe23c1d` |
| SRFI 261 | `srfi-261/srfi-261.html` | `https://srfi.schemers.org/srfi-261/srfi-261.html` | `2ecbd1d99a844410c1954b3459be19d7a4fb4841e065831f908cadd945373e9f` |
| R7RS-large Red Edition report | `r7rs-large/2016-07-red-edition-report.md` | `https://codeberg.org/scheme/r7rs/src/branch/main/ballot-results/jcowan/edition/2016-07-red-edition-report.md` | `f7c035f969d4b4883765ebcdbd339db6316f6f71a6ee23aa7d1dd0a12bd38066` |
| R7RS-large Tangerine Edition report | `r7rs-large/2019-02-tangerine-edition-report.md` | `https://codeberg.org/scheme/r7rs/src/branch/main/ballot-results/jcowan/edition/2019-02-tangerine-edition-report.md` | `7efd3915d2c28bdf76ed4bdb12c96e7d37992211f86cee5d2d98505fbbb66a7a` |
| R7RS-large Yellow Edition report | `r7rs-large/2022-02-yellow-edition-report.txt` | `https://codeberg.org/scheme/r7rs/src/branch/main/ballot-results/jcowan/edition/2022-02-yellow-edition-report.txt` | `cd78f6299f4efea2cb8421145c0a9a468a6d00f1b117edfe969b4b75cb8991cc` |
| R7RS-large report permission | `r7rs-large/LICENCE.txt` | `https://codeberg.org/scheme/r7rs/src/branch/main/LICENCE.txt` | `dfc682d45bfc7af900edd02365fed6e5484a93b60846f80844f42b80ee458330` |
