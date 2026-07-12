# Standard Library Reference Corpus

This directory stores local reference material for externally defined optional
standard libraries implemented by Consent Scheme's stdlib layer.

Stdlib manifest `local-reference-documents` paths are relative to
`scheme/stdlib/manifest.sld`, so entries point into this directory as
`reference/...`.

The `srfi-*` directories retain upstream HTML snapshots from
`https://srfi.schemers.org/` and generated Markdown renderings of those
snapshots. Manifests link the Markdown rendering; the HTML remains the auditable
conversion input. Both forms are vendored third-party reference documents, not
authored Consent Scheme documentation. Each generated Markdown file carries
explicit MIT SPDX metadata and preserves the upstream copyright and permission
text.

Regenerate every SRFI Markdown document from its local HTML source with:

```sh
tools/convert-srfi-reference.sh
```

The converter requires `pandoc` and `mdformat`, preserves raw HTML where GFM
cannot faithfully represent the source, and keeps superscript/subscript markup.
Use `tools/convert-srfi-reference.sh --check` to verify that committed output is
stable. After conversion, update the generated hashes in the inventory below;
source hashes change only when a new upstream HTML snapshot is intentionally
vendored.

The `r7rs-large` directory contains R7RS-large ballot and edition snapshots
from the official `scheme/r7rs` Codeberg repository. Those reports are vendored
as reference documents under the report-copying permission recorded in
`r7rs-large/LICENCE.txt` and in `LICENSES/LicenseRef-R7RS-Report-Permission.txt`.

## SRFI Conversion Inventory

| Reference | Generated Markdown | Markdown SHA-256 | Source HTML | Source SHA-256 | Upstream URL |
| --- | --- | --- | --- | --- | --- |
| SRFI 0 | `srfi-0/srfi-0.md` | `f01d764c56f7b1961588107334b1a1a52972b86887d4b00ceae8415a9c1ccaaa` | `srfi-0/srfi-0.html` | `2a831d143df6d73ea10f2ab1323c7340f0964c21d55d95f34a323bc89a7144eb` | `https://srfi.schemers.org/srfi-0/srfi-0.html` |
| SRFI 1 | `srfi-1/srfi-1.md` | `0f1d67fbc4136191cc34da56f9fdea581f516f48edf0f79c1e0d4f4ba149df4f` | `srfi-1/srfi-1.html` | `db1bdaff7f13b25f5f16426481463867ce269e30fdf5586b04b75581f53aafd8` | `https://srfi.schemers.org/srfi-1/srfi-1.html` |
| SRFI 2 | `srfi-2/srfi-2.md` | `fb27ee648b4390109261cded898f65de1a34346d54395fb04f6c44cc1e96250a` | `srfi-2/srfi-2.html` | `04d8485a010d6d2149294b2da91c10a1b85bdf4014426b4e9db6809d5f4b232f` | `https://srfi.schemers.org/srfi-2/srfi-2.html` |
| SRFI 8 | `srfi-8/srfi-8.md` | `380d22721f42bd43d89b1acffa101ef9357379115454cf860c2ec6dda1df57ae` | `srfi-8/srfi-8.html` | `745e473cbe3062150587b9e9412603caa53b452c1dd6648f3e3cdaad8eff33eb` | `https://srfi.schemers.org/srfi-8/srfi-8.html` |
| SRFI 16 | `srfi-16/srfi-16.md` | `67a66bf4e85fc135f598113c6e4427c342cd05889fb0e864008a4b8eeca7d15f` | `srfi-16/srfi-16.html` | `a2a16ebe3811e36a12a4eee69665ba739bdd88f67d04563f4ad80ca35c590fbd` | `https://srfi.schemers.org/srfi-16/srfi-16.html` |
| SRFI 27 | `srfi-27/srfi-27.md` | `8f7c2838b17ac362d99ca176be6e406c08ad800e00de92eb62d79965c6e8f94d` | `srfi-27/srfi-27.html` | `505040519b7d44a26152e424d932dec72dbb53eee153314189f9cc15bb88ac8e` | `https://srfi.schemers.org/srfi-27/srfi-27.html` |
| SRFI 42 | `srfi-42/srfi-42.md` | `793308520cee6cf040094a569c3d66728ec9f11c4e5479e5c7ad608c9cdf8ab2` | `srfi-42/srfi-42.html` | `b6ab81485f568bccdb43358ec2a0ef4fa906d0a5c068588a243d95f087073daf` | `https://srfi.schemers.org/srfi-42/srfi-42.html` |
| SRFI 64 | `srfi-64/srfi-64.md` | `8b76634559386c75e4a038496d1afcae10ed1df20bc064161f6ed4506452740f` | `srfi-64/srfi-64.html` | `ad4b7ab6c2137c997e21d3a0c2a347ee99f2837ad79467200d0b63bff8cfb1a5` | `https://srfi.schemers.org/srfi-64/srfi-64.html` |
| SRFI 78 | `srfi-78/srfi-78.md` | `6d021572d38f6c59dd5a0cbff2c702acf29284ddd71a1dc28510a88a72c42af7` | `srfi-78/srfi-78.html` | `fefdfc94bae8c692c078bb16217b06c4373f835a3d4072cf78526c596b5a3924` | `https://srfi.schemers.org/srfi-78/srfi-78.html` |
| SRFI 97 | `srfi-97/srfi-97.md` | `f2d610b09ccb0c9e2304bb8dfe6775d81ddf63d45da9884c3ae78f84e9d9c26d` | `srfi-97/srfi-97.html` | `a0572a9fd50bead52d86ffa1a589f00e013a0ad0842a837026d076134b3bfb43` | `https://srfi.schemers.org/srfi-97/srfi-97.html` |
| SRFI 128 | `srfi-128/srfi-128.md` | `42636329a3085368ef7faedc72e4dbcf7a7fc32ee045d4ed9b00260aa866683f` | `srfi-128/srfi-128.html` | `e981d747fc5f53bcc72f6868333a35cf056b198386b80541a2ff266916c9fa97` | `https://srfi.schemers.org/srfi-128/srfi-128.html` |
| SRFI 145 | `srfi-145/srfi-145.md` | `51d184e3c5c3afeb77af26ae196be28cf76f66235062639b05a3b7e460c88cc3` | `srfi-145/srfi-145.html` | `fb1478fcc3060bc39005a521dfae8743a080ed72dcdc72c9fc61df6077667fa6` | `https://srfi.schemers.org/srfi-145/srfi-145.html` |
| SRFI 146 | `srfi-146/srfi-146.md` | `bc4d560950a75c4dcbc5881fff600e9fca42add24ed4c8213ae0fbe9715c01e4` | `srfi-146/srfi-146.html` | `70ed5d8e30f7eb4d8bfdbf56e51943ee1dfaf1404392e175551819531fc9eab0` | `https://srfi.schemers.org/srfi-146/srfi-146.html` |
| SRFI 158 | `srfi-158/srfi-158.md` | `2f8d284c7a595378a604825bdf9e42699f22504fd00b8cad21fe8d89e9f4bc98` | `srfi-158/srfi-158.html` | `c4bb02803ddf8000e93ac9ab766bc0a1cd86cc8810e55ae87e8b5aa593802b69` | `https://srfi.schemers.org/srfi-158/srfi-158.html` |
| SRFI 180 | `srfi-180/srfi-180.md` | `6382a0b28f9e373ebfa974add1206a19b0ea53dabb956fb350378de316aa7aeb` | `srfi-180/srfi-180.html` | `a92f2442382c1074895814385ef5314f62ae85e698d93ffad840f92dbfe23c1d` | `https://srfi.schemers.org/srfi-180/srfi-180.html` |
| SRFI 194 | `srfi-194/srfi-194.md` | `7368ceff4a2ccb54b25c98d385a3e02e1458512b5a890abd5a8ee583565a07ed` | `srfi-194/srfi-194.html` | `fb4a4b5e853ded8e69612c79e55763156d1bccf312657c47b9c5610892894f98` | `https://srfi.schemers.org/srfi-194/srfi-194.html` |
| SRFI 252 | `srfi-252/srfi-252.md` | `941c93f54103248bba07013a4d76c9e0d6a23bdc258099beb6c17d0fb6ed0285` | `srfi-252/srfi-252.html` | `00089d9c2f5d9556f931711cdff341ee7b3e70a010a82e24d310884ae2730429` | `https://srfi.schemers.org/srfi-252/srfi-252.html` |
| SRFI 261 | `srfi-261/srfi-261.md` | `0ed87cff531b71c0536e071e5f8f0fa6ad3a928a2cd0baff24796329f42b9b12` | `srfi-261/srfi-261.html` | `2ecbd1d99a844410c1954b3459be19d7a4fb4841e065831f908cadd945373e9f` | `https://srfi.schemers.org/srfi-261/srfi-261.html` |

## Other Snapshot Inventory

| Reference | Local path | Upstream URL | SHA-256 |
| --- | --- | --- | --- |
| R7RS-large Red Edition report | `r7rs-large/2016-07-red-edition-report.md` | `https://codeberg.org/scheme/r7rs/src/branch/main/ballot-results/jcowan/edition/2016-07-red-edition-report.md` | `f7c035f969d4b4883765ebcdbd339db6316f6f71a6ee23aa7d1dd0a12bd38066` |
| R7RS-large Tangerine Edition report | `r7rs-large/2019-02-tangerine-edition-report.md` | `https://codeberg.org/scheme/r7rs/src/branch/main/ballot-results/jcowan/edition/2019-02-tangerine-edition-report.md` | `7efd3915d2c28bdf76ed4bdb12c96e7d37992211f86cee5d2d98505fbbb66a7a` |
| R7RS-large Yellow Edition report | `r7rs-large/2022-02-yellow-edition-report.txt` | `https://codeberg.org/scheme/r7rs/src/branch/main/ballot-results/jcowan/edition/2022-02-yellow-edition-report.txt` | `cd78f6299f4efea2cb8421145c0a9a468a6d00f1b117edfe969b4b75cb8991cc` |
| R7RS-large report permission | `r7rs-large/LICENCE.txt` | `https://codeberg.org/scheme/r7rs/src/branch/main/LICENCE.txt` | `dfc682d45bfc7af900edd02365fed6e5484a93b60846f80844f42b80ee458330` |
