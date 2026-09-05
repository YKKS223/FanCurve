# FanCurve

Apple シリコン Mac 向けのカスタムファンカーブアプリ。macOS 標準より早くファンを回して、
高負荷時に熱がこもるのを防ぎます。

検証環境: MacBook Pro (Mac15,10 / Apple M3 Max) / macOS 26.6.2 / Swift 6.3.3

> 調査の過程でわかったこと（SMC の仕様、macOS の熱管理の仕組み、実測値、公開情報の誤り）は
> **[FINDINGS.md](FINDINGS.md)** にまとめてあります。この README は使い方、FINDINGS は調査結果です。

---

## なぜ作るか — 実測した macOS 標準の挙動

制御ソフトを一切入れない状態で 900 秒記録した結果（`fancurvectl watch`）:

| 温度 | macOS 標準のファン |
|---|---|
| 〜80 °C | **0 rpm（停止）** |
| 80〜106 °C | **2,317 rpm に張り付き**（最低回転のまま 26 °C 分） |
| 106 °C〜 | ようやくランプ開始 |
| 117.6 °C（最高到達） | 5,006 rpm = **定格の 73%**。上限は使わない |

ローカル LLM を回すと **110 °C 超が 80 秒、100 °C 超が 135 秒**。静かなのは、熱を許容しているからです。
このアプリは 60 °C 台から回し始めて、この帯域に入らせないことを狙います。

---

## できること

- **カスタムファンカーブ** — 温度 → 回転数を点のドラッグで編集。ファンごとに別カーブ
- **macOS 標準カーブを併記** — 実測値をグレーの破線で重ねて表示。差が一目で分かります
- **温度ソース選択** — CPU / GPU / SoC / SSD / 筐体 のグループ最高温度、または 271 個の個別センサー
- **回転数の上限** — 定格上限まで回さない。既定は定格の 80%
- **3 モード** — システム標準 / カーブ / 手動
- **プリセット** — 静音 / バランス / 冷却重視 / 最大（すべて実測ベースライン基準で設計）
- **ヒステリシス・平滑化・加減速リミット**
- **メニューバー常駐**と履歴グラフ

---

## 仕組み

### SMC のファン制御（M3 世代以降）

macOS の `thermalmonitord` がファンを mode 3 に保持し、mode キーへの書き込みを **status 0x82** で拒否します。
`Ftst`（Force Test / 診断モード）で解除するのが正解でした。

```
1. F%dMd = 1 を直接試す              ← M1 世代はこれで通る
2. 拒否されたら Ftst = 1              ← thermalmonitord の回収を抑止
3. F%dMd が 3 を抜けるまでポーリング   ← 100 ms 間隔・最大 10 秒
4. F%dMd = 1 → F%dTg = <rpm>
5. 手放すときは Ftst = 0              ← 実測 2.9 秒で mode 3 に復帰
```

実測でわかった注意点:

- **`Md=3` の間、`F%dTg` の書き込みは「受理」されるが完全に無視される**（ファンは回らない）
- **`F%dTg` は共有レジスタ**。macOS 自身も書き込むので、読み戻しは信用できない
  （書いた直後に 0 を返し、0 を書いた後に古い値を返す）。UI は「デーモンが指示した値」を表示します
- `Md=0`（macOS が管理中）に `Ftst` 無しで書いても **1 ms で上書きされる**。200 Hz で書いても勝てません
- `F%dMn`/`F%dMx` は目安で、firmware は強制しません。クランプはこちらの責任
- `F%dTg` 書き込みの `0x87` は「エラーだが書けている」ことがあるので成功扱い
- M5 は mode キーが小文字 `F%dmd` で `Ftst` が無い（未検証）

### プロセス構成

SMC 書き込みには root が要るので、**root デーモン + 一般ユーザー GUI** の 2 プロセス構成です。

```
FanCurve.app (ユーザー権限, SwiftUI)
        │  UNIX ドメインソケット /var/run/fancurved.sock（改行区切り JSON）
        ▼
fancurved (root, LaunchDaemon)  ──▶  AppleSMC (IOKit)
```

---

## 安全設計

**前提: ハードウェアに deadman はありません。** `Ftst=1` かつ手動モードのままプロセスを `SIGKILL` して
90 秒観測したところ、macOS は一切回収しませんでした。Linux カーネルの
[macsmc-hwmon](https://docs.kernel.org/hwmon/macsmc-hwmon.html) も手動ファン制御を unsafe とし
「過熱時に安全側に倒れることを証明できない」と明記しています。
Macs Fan Control でも[同種の過熱事故](https://github.com/crystalidea/macs-fan-control/issues/387)が報告されています。

そのうえで、多層に組んでいます。

### 1. 論理は許可証方式（構造的に安全側）

制御は「状態」ではなく、**毎サイクル発行される許可証**です。許可証がゼロなら全解放。
**解放は分岐ではなく、許可証が無いことの自然な帰結**なので、例外・条件外・早期 return・
センサー欠損のいずれも、何もしなければ解放側に落ちます。「信号の初期状態は赤」の実装です。

### 2. アプリの生存がデッドマン（ハードに無い仕組みを補う）

デーモンは **GUI からの生存確認が 5 秒途切れると自動でファンを macOS へ返します**。
アプリの終了・クラッシュ・ログアウトで、**誰も後片付けをしなくても**許可が失効します。
継電器が電流を失って落ちるのと同じ構造を、プロセス境界を越えて作ったものです。（既定オン）

### 3. 充電中のみブースト（既定オン）

バッテリー駆動中は握りません。ファンの消費は数 W あり、アイドル時のシステム全体（約 8 W）
に対して無視できない割合だからです。

### 4. 固着しても危険でない向きに倒す

- **ブースト中は 2,500 rpm を下回る値を絶対に書かない。** macOS が 80〜106 °C で使う 2,317 rpm を上回るので、
  万一固着しても「うるさいだけ」で、その帯域で標準より悪くなりません
- **カーブが下限未満を要求したら、そもそも握らない。** 切り上げて回すのは、静かさを求めた人にとって害でしかありません
- **カーブが 0 rpm を指示したら `Tg=0` ではなく `Ftst=0`。** `Ftst` を握ったまま `Tg=0` は
  「macOS を締め出したままファンを止める」最悪の状態です

### 5. 安全下限は「標準より悪くならない」ことだけを保証

| 温度 | 安全下限 | macOS 標準（実測） |
|---|---|---|
| 〜100 °C | なし（ブースト下限 2,500 rpm が既に上回る） | 2,317 rpm |
| 106 °C | 定格の 34% | 2,317 rpm（ここからランプ開始） |
| 117 °C | 定格の 75% | 5,006 rpm（73%） |
| 120 °C | 100% | — |

安全下限は**冷却の好みではなく、標準を下回らないための最低保証**です。それ以上はカーブと上限が決めます。

### 6. その他

- **緊急冷却**: 2 個以上のセンサーが 105 °C を 2 サイクル連続で超えたら全ファン最大。
  カーブ・上限・充電条件・アプリ条件のすべてを無視します
- **起動時の自己修復**: センサー走査より前に `Ftst` を確認し、1 なら 0。前回の異常終了を打ち消します
- **launchd `ThrottleInterval=1`**: 既定の 10 秒だとクラッシュ後 11.1 秒 `Ftst` が残りました。1 秒指定で **1.2 秒**（実測）
- **`ExitTimeOut=20`**: 再起動・システム終了・ログアウト時に `SIGTERM` を捕まえて `Ftst=0`
- **ウォッチドッグ**: 制御ループが 10 秒止まったら自ら終了し、launchd に再起動させる
- **フェイルセーフ**: 温度が読めない / 値が固まった / 書き込みが連続失敗 → すべて macOS へ返す
- **毎サイクルの自己検証**: スリープ復帰で firmware が `Ftst` をリセットしても握り直します

### 残るリスク

**カーネルパニック・電源ボタン長押し・電源喪失**の瞬間に `Ftst=1` だった場合は消せません。
ただしパニックは自動再起動し、起動時に `Ftst=0` を書きます。電源が切れれば発熱も止まります。
そして規則 4 により、残るのは「ファンが速い」状態です。

---

## 必要なもの

| | |
|---|---|
| ハードウェア | **Apple シリコンの Mac**（Intel Mac では動きません）。ファンのある機種 |
| OS | macOS 14 以降。開発・検証は macOS 26.6.2 |
| ビルド | **Xcode または Command Line Tools**（`xcode-select --install`）。Swift 5.9 以降 |
| 権限 | インストールと実行に **管理者パスワード**（`sudo`）が必要です |

コード署名はアドホックなので、**ソースからビルドして自分でインストールする**形になります。
配布用の署名済みパッケージはありません。

---

## インストール

```bash
cd ~/Documents/test_apps/fancurve
./scripts/build.sh              # sudo 不要
sudo ./scripts/install.sh       # デーモン登録 + /Applications へ
open /Applications/FanCurve.app
```

> アプリは**メニューバーに常駐**します。ウィンドウを閉じても終了しません。
> 更新を反映するには ⌘Q で完全に終了してください（`install.sh` は自動で終了させます）。
> 設定タブの「このアプリのビルド」で、動いているものが最新か確認できます。

| パス | 内容 |
|---|---|
| `/usr/local/libexec/fancurved` | デーモン |
| `/usr/local/bin/fancurvectl` | CLI |
| `/Library/LaunchDaemons/com.local.fancurved.plist` | 起動設定 |
| `/Applications/FanCurve.app` | GUI |
| `/Library/Application Support/FanCurve/config.json` | 設定 |
| `/var/log/fancurved.log` | ログ |

---

## 普段の使い方

インストールは**最初の一度だけ**です。以後ターミナルは不要です。

- **デーモンは Mac の起動時に自動で動きます**（LaunchDaemon）。何もしなくて構いません
- **ブーストしたいときに `FanCurve.app` を開くだけ**です。既定では
  「アプリ起動中」かつ「充電中」のときだけファンを握ります
- 使い終わったら **⌘Q で終了**すれば、ファンは macOS に戻ります
- ウィンドウを閉じただけでは常駐したままで、ブーストも続きます

### 自動起動させたい場合

システム設定 →「一般」→「ログイン項目と機能拡張」→ ログイン時に開く項目に
`/Applications/FanCurve.app` を追加します。ただし**常にブーストが有効な状態**になるので、
静かに使いたい時間帯があるなら手動起動のほうが向いています。

---

## CLI

```bash
fancurvectl status              # 温度・回転数・モード・いま誰が握っているか
fancurvectl sensors --all       # 全センサー
fancurvectl mode curve|system|manual
fancurvectl manual 0 3000       # 手動モードの回転数
fancurvectl config              # 設定 JSON
fancurvectl reset               # ファンを macOS へ返す
sudo fancurvectl panic          # Ftst=0 を直接書いて強制復帰
```

計測・診断用（root 不要のものは書き込みを一切しません）:

```bash
fancurvectl watch 900 out.tsv   # 温度と回転数を1秒ごとに記録（読み取りのみ）
fancurvectl keys Ftst F0Md      # 任意の SMC キーを読む（読み取りのみ）
sudo fancurvectl unlocktest     # Ftst 解除手順の実行と復帰の検証
sudo fancurvectl diag           # 制御方式を総当たり、SMC の生ステータスを表示
sudo fancurvectl contest        # macOS が制御中に奪えるか（奪えません）
sudo scripts/crashtest.sh       # SIGKILL 後に macOS が回収するか（しません）
sudo scripts/daemon-crashtest.sh # デーモンのクラッシュから復帰までの実測
sudo scripts/restart-latency.sh 4 1  # launchd の再起動レイテンシ（SMC に触れません）
```

---

## Apple シリコンのセンサー

Intel の `TC0P` / `TG0D` は存在せず、ダイ上の測定点が数百個あります（この機体で 271 個）。

| 接頭辞 | 分類 | 個数 |
|---|---|---|
| `Tp` `Te` | CPU（P/E コアクラスタ） | 106 |
| `Tg` | GPU | 32 |
| `TC` `TV` `TP` `TS` `TM` | SoC / 電源系 | 50 |
| `TH` `Th` | SSD | 15 |
| `Ts` `Ta` `TA` `TW` | 筐体・吸気・無線 | 25 |
| `TB*T` | バッテリー | 3 |

個別コアは一瞬で 10 °C 動くので、既定は**グループ最高温度**で駆動します。
`systemMax` はバッテリーと筐体を除いた最高値です（追従が鈍く、ファン制御に使えないため）。
**`Tf**` は温度センサーではありません** — フル負荷を 30 秒かけても 73.4 / 71.5 °C から動かない固定値でした。

---

## 別の Mac で使う場合（機種変・GitHub から導入）

```bash
git clone <このリポジトリ> fancurve
cd fancurve
./scripts/build.sh
sudo ./scripts/install.sh
open /Applications/FanCurve.app
```

ビルドと初回インストールにはターミナルが必要です。以後は不要です。

### 導入したら必ず確認すること

このアプリの安全設計は、**この MacBook Pro (M3 Max) で実測した値**に基づいています。
機種が変われば数字も変わるので、次の 3 つは新しい機体で取り直してください。

**1. 制御方式が同じか**（約 1 分・アイドルのまま）

```bash
sudo fancurvectl unlocktest
```

`Ftst` 経由で手動モードに入れて、`Ftst=0` で戻れることを確認します。
うまくいかない場合は `sudo fancurvectl diag` で SMC の生ステータスを見てください。
M5 世代は mode キーが小文字 `F%dmd` で `Ftst` が無いとされており、**未検証**です。

**2. その機体の macOS 標準の挙動**（15 分・LLM などで負荷をかける）

```bash
fancurvectl watch 900 ~/Desktop/baseline.tsv     # 読み取りのみ・root 不要
```

**アプリをアンインストールした状態か「システム標準」モードで**実行してください。
「何 °C でファンが回り始め、どこまで最低回転に張り付き、最大何 rpm まで回すか」が分かります。

**3. 実測値に合わせて定数を直す**

| 定数 | 場所 | この機体の値 | 意味 |
|---|---|---|---|
| `StockBaseline.points` | `Sources/FanCurveKit/StockBaseline.swift` | 80 °C まで 0、106 °C まで 33.6%、117.6 °C で 73% | グラフに重ねる「Apple 標準」の線。**測り直さないと嘘になります** |
| `SafetyFloor.points` | `Sources/FanCurveKit/SafetyFloor.swift` | 100 °C まで 0、106 °C で 34%、117 °C で 75% | 「標準を下回らない」ための最低保証。標準がもっと早くランプする機体では前倒しが必要 |
| `emergencyTempC` | 設定 GUI | 105 °C | この機体は標準が 117 °C まで許容するので高め。もっと低温で回る機体なら下げてよい |
| `maxRPMCap` | 設定 GUI | 定格の 80% | 標準が使う上限（この機体は 73%）より少し上に |

`BoostPlan.defaultFloorRPM`（2,500 rpm）だけは**そのままで構いません**。実際に使われるのは
`max(2500, そのファンの最小回転数)` で、標準が張り付くのはどの機体でもファンの最小回転数なので、
自動的に「標準以上」が保証されます。

### リポジトリに含めるもの

`.gitignore` で `.build/`（310 MB）と `build/` を除外しています。
ソース・スクリプト・テスト・この README だけをコミットしてください。
`/Library/Application Support/FanCurve/config.json` は機体ごとの設定なので、リポジトリには含めません。

---

## macOS をアップデートしたら確認すること

このアプリは**非公開の SMC 挙動と `thermalmonitord` の内部**に依存しています。OS 更新で
前提が変わっても警告は出ないので、メジャーアップデート後は一度確認してください。
所要 5 分、発熱なし。

```bash
# 1. 解除手順がまだ通るか（約40秒・アイドルのまま）
sudo fancurvectl unlocktest

# 2. 普段どおり使って、握れているか
fancurvectl status        # 高温時に「🔒 このアプリが保持中」になるか
```

`unlocktest` が失敗する場合は `sudo fancurvectl diag` で SMC の生ステータスを見てください。
挙動が変わっていた場合は、[FINDINGS.md](FINDINGS.md) の数値も取り直しが必要です。

異常が出たらまずこれで元に戻せます:

```bash
sudo fancurvectl panic          # Ftst=0 を直接書いてシステム制御へ
```

---

## アンインストール

```bash
sudo ./scripts/uninstall.sh
```

ファンを macOS に返してから、デーモン・CLI・アプリを削除します（設定は残ります）。

---

## 開発

```bash
swift build && swift test      # ユニットテスト 63 件
./scripts/build.sh             # リリース + .app 組み立て

# インストールせずに動かす（root でないので読み取り専用）
FANCURVE_SOCKET=/tmp/fc.sock FANCURVE_CONFIG=/tmp/fc.json FANCURVE_VERBOSE=1 .build/debug/fancurved
```

### 既知の制限

- ファンレス機種では `FNum` が 0 になり、温度表示のみになります
- コード署名はアドホックです（Developer ID なし）。配布はできません
- GUI のドラッグ操作は実機での目視確認が必要です
- M5 世代（小文字 `F%dmd`・`Ftst` なし）は未検証です
