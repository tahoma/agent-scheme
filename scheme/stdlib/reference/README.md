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

The converter requires `pandoc` and `mdformat`, wraps ordinary prose to 80
columns for readable text-file review, preserves raw HTML where GFM cannot
faithfully represent the source, and keeps superscript/subscript markup. Use
`tools/convert-srfi-reference.sh --check` to verify that committed output is
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
| SRFI 0 | `srfi-0/srfi-0.md` | `70b4a4715264d3f5e2988fd1890b8b13a20b266a163c63fe0afa6c2d454faa24` | `srfi-0/srfi-0.html` | `2a831d143df6d73ea10f2ab1323c7340f0964c21d55d95f34a323bc89a7144eb` | `https://srfi.schemers.org/srfi-0/srfi-0.html` |
| SRFI 1 | `srfi-1/srfi-1.md` | `c4753ef54a12e71b5fb534eef5f4c80f773a2a260f662fb5a49ad8c60a036914` | `srfi-1/srfi-1.html` | `db1bdaff7f13b25f5f16426481463867ce269e30fdf5586b04b75581f53aafd8` | `https://srfi.schemers.org/srfi-1/srfi-1.html` |
| SRFI 2 | `srfi-2/srfi-2.md` | `aeb9866b05465349a3b9af46547be5ab31d9b2d02763c8929fd6ada1da0a795b` | `srfi-2/srfi-2.html` | `04d8485a010d6d2149294b2da91c10a1b85bdf4014426b4e9db6809d5f4b232f` | `https://srfi.schemers.org/srfi-2/srfi-2.html` |
| SRFI 8 | `srfi-8/srfi-8.md` | `e62bb2cd3404646c57303ce7bed982e2d2db59f9cc828bac4ac1322e98efdd9e` | `srfi-8/srfi-8.html` | `745e473cbe3062150587b9e9412603caa53b452c1dd6648f3e3cdaad8eff33eb` | `https://srfi.schemers.org/srfi-8/srfi-8.html` |
| SRFI 16 | `srfi-16/srfi-16.md` | `ad6815c5745bb55198e55eadb1ad3fc22246b8484ab67eadb321983460cab9dd` | `srfi-16/srfi-16.html` | `a2a16ebe3811e36a12a4eee69665ba739bdd88f67d04563f4ad80ca35c590fbd` | `https://srfi.schemers.org/srfi-16/srfi-16.html` |
| SRFI 27 | `srfi-27/srfi-27.md` | `43dd61fc25dfaf9a1b741790c9adb03427b12ac24175b81494e93e46fdcf1076` | `srfi-27/srfi-27.html` | `505040519b7d44a26152e424d932dec72dbb53eee153314189f9cc15bb88ac8e` | `https://srfi.schemers.org/srfi-27/srfi-27.html` |
| SRFI 42 | `srfi-42/srfi-42.md` | `11edc75403331b6b914e7d9040b8f6405a92f245b406dcb18a3440a67e269c0a` | `srfi-42/srfi-42.html` | `b6ab81485f568bccdb43358ec2a0ef4fa906d0a5c068588a243d95f087073daf` | `https://srfi.schemers.org/srfi-42/srfi-42.html` |
| SRFI 64 | `srfi-64/srfi-64.md` | `65c7ffbaea01680c613e6f5e0d8b833c606b5466c2098cc696992110afc20170` | `srfi-64/srfi-64.html` | `ad4b7ab6c2137c997e21d3a0c2a347ee99f2837ad79467200d0b63bff8cfb1a5` | `https://srfi.schemers.org/srfi-64/srfi-64.html` |
| SRFI 78 | `srfi-78/srfi-78.md` | `881872a342807699da8f2b121d15791d6c32c81f173e67f44335ea586d1d4fc5` | `srfi-78/srfi-78.html` | `fefdfc94bae8c692c078bb16217b06c4373f835a3d4072cf78526c596b5a3924` | `https://srfi.schemers.org/srfi-78/srfi-78.html` |
| SRFI 97 | `srfi-97/srfi-97.md` | `161d61896685ee0ef9817ebd33ad15175f40248a6ec2d325393a8eda7009ed99` | `srfi-97/srfi-97.html` | `a0572a9fd50bead52d86ffa1a589f00e013a0ad0842a837026d076134b3bfb43` | `https://srfi.schemers.org/srfi-97/srfi-97.html` |
| SRFI 128 | `srfi-128/srfi-128.md` | `a8e0edac967db0fd797a58ce3a95c5f484e11be203f21de93f06e43ef4d06bb8` | `srfi-128/srfi-128.html` | `e981d747fc5f53bcc72f6868333a35cf056b198386b80541a2ff266916c9fa97` | `https://srfi.schemers.org/srfi-128/srfi-128.html` |
| SRFI 145 | `srfi-145/srfi-145.md` | `0e5d47406233c8aa371a216f974920394f8a8d0e33f3bde00c736da7fef8b0b1` | `srfi-145/srfi-145.html` | `fb1478fcc3060bc39005a521dfae8743a080ed72dcdc72c9fc61df6077667fa6` | `https://srfi.schemers.org/srfi-145/srfi-145.html` |
| SRFI 146 | `srfi-146/srfi-146.md` | `ced4fd2b7465e2e83b415ebda556719aaa29ada8a0da54cb0859fefbcca08041` | `srfi-146/srfi-146.html` | `70ed5d8e30f7eb4d8bfdbf56e51943ee1dfaf1404392e175551819531fc9eab0` | `https://srfi.schemers.org/srfi-146/srfi-146.html` |
| SRFI 158 | `srfi-158/srfi-158.md` | `091f7c42d8370ef9fa470739bda155cdf8958d65fb6f13c4b55d81afc6c79694` | `srfi-158/srfi-158.html` | `c4bb02803ddf8000e93ac9ab766bc0a1cd86cc8810e55ae87e8b5aa593802b69` | `https://srfi.schemers.org/srfi-158/srfi-158.html` |
| SRFI 180 | `srfi-180/srfi-180.md` | `9140a40ff1aadcaaf54dc68de414ed965c30007e8e2d1b8ba0b48c7f67fb0257` | `srfi-180/srfi-180.html` | `a92f2442382c1074895814385ef5314f62ae85e698d93ffad840f92dbfe23c1d` | `https://srfi.schemers.org/srfi-180/srfi-180.html` |
| SRFI 194 | `srfi-194/srfi-194.md` | `2cb78a0362b2ac8ae660026b0cc569f6fd55947290252d941ef29cad5044dfa1` | `srfi-194/srfi-194.html` | `fb4a4b5e853ded8e69612c79e55763156d1bccf312657c47b9c5610892894f98` | `https://srfi.schemers.org/srfi-194/srfi-194.html` |
| SRFI 214 | `srfi-214/srfi-214.md` | `507f1c32ebc3a955fe2ac173eb6a253575621b28e67296404bda3ce16985b051` | `srfi-214/srfi-214.html` | `c394faf9aad6170349bc0e8adcbdb9a153c83dd7cf0419e587b62b5b0b423a79` | `https://srfi.schemers.org/srfi-214/srfi-214.html` |
| SRFI 252 | `srfi-252/srfi-252.md` | `6e5bae21aec1d0cca3104780f440439232bb7e01268a7abaa3ff7ff77e1a9d65` | `srfi-252/srfi-252.html` | `00089d9c2f5d9556f931711cdff341ee7b3e70a010a82e24d310884ae2730429` | `https://srfi.schemers.org/srfi-252/srfi-252.html` |
| SRFI 261 | `srfi-261/srfi-261.md` | `3ccd88d575e4595e2d8d1c7a77e73dfc15d6bc09bd33d0b1e9a4d5c0733e8bd8` | `srfi-261/srfi-261.html` | `2ecbd1d99a844410c1954b3459be19d7a4fb4841e065831f908cadd945373e9f` | `https://srfi.schemers.org/srfi-261/srfi-261.html` |

## Other Snapshot Inventory

| Reference | Local path | Upstream URL | SHA-256 |
| --- | --- | --- | --- |
| R7RS-large Red Edition report | `r7rs-large/2016-07-red-edition-report.md` | `https://codeberg.org/scheme/r7rs/src/branch/main/ballot-results/jcowan/edition/2016-07-red-edition-report.md` | `f7c035f969d4b4883765ebcdbd339db6316f6f71a6ee23aa7d1dd0a12bd38066` |
| R7RS-large Tangerine Edition report | `r7rs-large/2019-02-tangerine-edition-report.md` | `https://codeberg.org/scheme/r7rs/src/branch/main/ballot-results/jcowan/edition/2019-02-tangerine-edition-report.md` | `7efd3915d2c28bdf76ed4bdb12c96e7d37992211f86cee5d2d98505fbbb66a7a` |
| R7RS-large Yellow Edition report | `r7rs-large/2022-02-yellow-edition-report.txt` | `https://codeberg.org/scheme/r7rs/src/branch/main/ballot-results/jcowan/edition/2022-02-yellow-edition-report.txt` | `cd78f6299f4efea2cb8421145c0a9a468a6d00f1b117edfe969b4b75cb8991cc` |
| R7RS-large report permission | `r7rs-large/LICENCE.txt` | `https://codeberg.org/scheme/r7rs/src/branch/main/LICENCE.txt` | `dfc682d45bfc7af900edd02365fed6e5484a93b60846f80844f42b80ee458330` |
