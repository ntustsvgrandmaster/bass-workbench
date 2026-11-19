# Bass Harmony Workbench 0.2

Apple Silicon 的本機採譜工作台。以「聽一小節、看音高能量、比較首音與 Root、人工確認」為主要流程。此版實作 Phase 1；不呼叫 LLM、不上傳音源、不下載模型。

## 使用

1. 開啟 `Bass Harmony Workbench.app`。已內附 Python 與音訊分析函式，不需另外設定 Python。
2. 「開啟專案」選擇 `.basswork`；或先匯入原曲，再匯入 MSCZ／MusicXML／MXL。有 Bass 或伴奏 stem 時再加入，並選擇正確的來源角色。
3. 點左側小節。展開「時間對齊與來源偏移」，找到實際第一拍，按「此刻＝小節起點」；找到下一小節起點，再按「此刻＝小節結尾」。可在不同位置建立更多錨點，速度變化會以分段線性方式對齊。錯誤錨點可刪除；時間必須依序增加。
4. 固定播放列提供播放／暫停、進度、0.5×／0.75× 與 A–B。預設跟隨播放更新小節，可關閉「跟隨播放」停留查看。點原譜或左側小節只定位並暫停；下方音符按鈕仍可試聽原音片段。拖曳波形可設定 A–B，手動輸入則需按「套用」；跨小節範圍不會被導覽改寫。
5. 按「分析目前範圍」。第一次啟用可能需要數十秒；後續使用快取。可取消後重試。音域預設 B0–C4，提供三種下限與每八度 12／24／36 格、對比及時間縮放。
6. 彩色圖表示各音高的能量；亮線也可能是諧波。白框是原譜音符、橙色虛線是起音候選、直線拍點來自手動對齊。這些疊圖皆可開關。
7. 右側分別顯示「小節／區間首音」、「推定 Root」、「和弦大方向」。Root 證據不足會留白，不會因此刪掉有依據的首音。和弦主標籤只提供 C／Cm 這類方向；品質不明時也可只顯示 Root。
8. 首音、Root、和弦都可輸入任意文字，並各自鎖定。鎖定空白表示確認暫無法判定。候選可以採用或忽略；「確認並鎖定」會保存目前可用的值。重新分析只更新自動證據，不覆寫人工欄位。
9. 一小節內有不同和聲時，將游標移到變化處，按「游標處拆分」。拆分以四分之一拍為最小格。已鎖定區間先解除確認再拆分；合併會保存原區間到歷史資料。
10. 「儲存專案」保存完整 `.basswork`，首次儲存可選位置，另存仍在 File 選單。編輯會持續自動儲存，退出再開會恢復上次專案；File 選單可顯示目前自動儲存位置。標題旁按「編輯」後才可改名，按「儲存」提交名稱，或「取消」放棄；不會更名原音、原譜或專案資料夾。
11. 「匯出／MuseScore」可匯出 JSON、CSV、完整 MusicXML 加已鎖定的和弦文字。MusicXML 從完整來源建立副本，只新增文字標註，不重建音符。可直接在 MuseScore 編輯原譜副本，完成後重新匯入。

## 第一版界線

- 尚無內建分軌、整首自動採譜、自動對齊、技巧辨識或 MIDI 產生。
- Bass 首音採用 CQT 低頻顯著度與週期性篩選，是原型候選方法，尚未經真實歌曲標註資料評估準確率。滑音、Ghost Note、Walking Bass、鼓與弱基頻仍可能誤判或留白。
- 和聲採用 HPSS／chroma 與大、小三和弦模板；不推論精確七和弦、調性或功能和聲。相似度分數不等於正確機率，前後行進目前只供人工比較。
- 原譜顯示鄰近小節，完整文件仍保留。播放以**書寫順序**對齊；尚未展開反覆記號、D.S.／D.C. 或多結尾。必須自行對齊相應段落，不能把整首 BPM 估算當成已校準。
- 單次 CQT 範圍上限 90 秒、最多 24 個和聲區間；A–B 上限 180 秒；音源上限一小時。使用局部區間可降低 8 GB Mac 的記憶體壓力。
- 支援 MusicXML partwise；MSCZ／MSCX 轉換需本機已安裝 MuseScore 4。MusicXML 的版面可能與 MuseScore 顯示不同；原始 MSCZ 另存保留。
- 工作台不提供完整音符編輯器。音高、時值、休止符與技巧的正式修改仍在 MuseScore 完成。重匯不同版本會保存舊區間標註，不自動對新譜挪用。
- 音訊必須能由 macOS 解碼；受保護的串流下載不能直接當一般檔案分析。
- 專案為包含原檔的資料夾套件，可能較大；請整包備份。音源及購買檔的原有中繼資料也保存在套件內。通用程式與原始碼 ZIP 不包含你的歌曲與樂譜。
- 此為 Apple Silicon arm64、本機 ad hoc 簽章測試版，沒有公證。宣告 macOS 14+，實測環境為 M2／8 GB／macOS 26.5.1；未在其他機型及系統版本驗證。不要停用系統安全保護。
- 與舊的 v0.1 `Bass Workbench.app` 分開；沒有舊 JSON 專案自動遷移。請使用新版 `.basswork` 或重新匯入原音與原譜。

## 資料與架構

```text
app/                       SwiftUI 原生 UI 與應用層
  Models.swift             精確拍數、穩定音符 ID、來源、區間、候選／人工狀態
  Audio.swift              串流解碼、分析副本、AVAudioEngine 播放／循環／變速
  ScoreIO.swift            MuseScore 轉換、完整 XML 保存、唯讀索引與註記副本匯出
  ProjectStore.swift       SQLite 交易；人工標註獨立保存
  WorkbenchStore.swift     專案生命週期、對齊、區間、undo／redo 與分析協調
  AnalysisWorker.swift     本機子程序 JSONL、進度、取消、重啟
  ScoreView.swift          本機 WKWebView／OSMD，攔截外部導覽
  Plots.swift              波形、CQT 影像快取、原譜／拍點／起音疊圖
  WorkbenchView.swift      逐小節工作介面
worker/                    可替換的 CPU DSP，不連網
  analysis.py              真正 CQT、onset、低頻首音、chroma／和弦模板、快取
  main.py                  JSONL 輸入／進度／結果／錯誤
resources/score-viewer/     內附 OSMD 2.2.1、授權、完整性資訊，無 CDN
requirements-lock.txt      驗證時固定的 Python 依賴
```

```text
歌曲.basswork/
  manifest.json
  project.sqlite           專案狀態、區間、自動證據、獨立人工標註、分析歷史
  originals/               原始音訊、MSCZ／MusicXML 的副本
  derived/audio/           單聲道 22.05 kHz WAV；播放仍使用原音
  derived/features/        方法版本＋來源 hash＋時間／參數決定的特徵與和聲快取
  derived/runtime/         可重建的 Python／Numba 快取
  exports/                 交給 MuseScore 的編輯副本
```

資料流：原曲／stems → macOS 解碼 → 本機 DSP → 可追溯候選；MusicXML → 唯讀音符索引 → 分段時間對齊 → 疊圖與逐區間判讀。人工標註另存且優先顯示。修改來源或對齊後，舊證據標為待更新，主標籤不再採用過期證據。

### 核心資料介面

- `ScoreNote`：來源 hash 衍生 ID、part／staff／voice／measure ID、分數形式的 onset／duration、書寫與實際音高、rest／grace／ghost、tie、string／fret。
- `TimingMap`：BPM、單調錨點、雙向分段線性時間映射及 revision。
- `HarmonyRegion`：小節內 beat 範圍；`HarmonyEvidence` 與 `HumanAnnotation` 分離。
- `HarmonyEvidence`：首音與時間、低音重心、Root／Chord 可空、多候選、chroma、來源 hash、方法、revision、時間戳及提示。
- `HumanAnnotation`：任意首音／Root／和弦文字、三個獨立 lock、ignored candidates、confirmed。
- Worker JSONL：`features`／`harmony` 指令接受來源、秒範圍及參數；回傳 `progress`／`result`／`error`。不直接寫入人工資料庫。

## 開發與重建

需要 Xcode Command Line Tools、Python 3.12 arm64，以及能重新定位的獨立 CPython 3.12 執行環境。一般使用者使用已打包 app 即可。

```sh
python3.12 -m venv .venv
.venv/bin/python -m pip install -r requirements-lock.txt
.venv/bin/python fetch_score_renderer.py
BASS_PYTHON_RUNTIME=/absolute/path/to/relocatable/python ./build.sh /absolute/output/folder
./test.sh
```

`BASS_PYTHON_RUNTIME` 是具有 `bin/python3.12`、`lib/python3.12` 的可重新定位 runtime，不能直接假設任何 framework Python 複製後都能獨立執行。這次使用此機既有的獨立 CPython runtime；亦可將已打包 app 的 `Contents/Resources/python` 作為同架構重建的基底。依賴與其授權會一併打包，OSMD 下載會驗證 npm 的 SHA512 完整性。

開發測試可使用 `BASS_DATA_ROOT` 指定自動保存位置、`BASS_OPEN_PROJECT` 開啟指定專案、`BASS_WORKER_PYTHON`／`BASS_WORKER_SCRIPT` 改用開發 worker。一般使用不需要這些設定。

授權：本專案程式碼 MIT；第三方套件依各自授權，見 `THIRD_PARTY_NOTICES.md` 及 app 內附授權文件。未包含分軌模型、付費服務或歌曲素材授權。


## 中文註解版

本次整理保留 v0.2.0 的程式行為，增加繁體中文註解並用 swift-format 展開 Swift 排版。沒有複製舊 `.venv`，可執行 app 的 Python 環境另完整保留。

## 2026-10-28 試用回饋修正（先前小幅更新）

- 切換小節或調整顯示範圍後，從專案內已完成且符合音源、偏移、方法與顯示參數的快取恢復音高能量圖；較大的快取依時間裁切顯示。沒有可用快取時仍需按「分析目前範圍」，不會自動重算。
- 「本機處理」與「首音與和聲」的常駐說明移至圈圈 i，點擊才顯示。
- 該次小幅更新僅處理快取與說明；後續功能見下方。開發 app 輸出於 `source/build/`，既有 app 保留。

## 第一階段操作修正

- 播放控制固定在上方，包含目前播放小節、全曲進度、速度、波形與 A–B。播放／定位時自動更新小節導覽、目前小節、鄰近譜面及和聲區間；輸入人工標註時暫緩切換，離開欄位後恢復。
- 點譜面或小節導覽只定位並暫停。A–B 只有明確設定時才變更，新增「本小節循環」；新專案預設關閉循環，既有專案的循環設定保留。
- A、B 手動輸入使用暫存文字，按「套用」或 Enter 才一起驗證。錯誤顯示在欄位下方，取消恢復已套用的範圍，循環上限維持 180 秒。
- 專案名稱改為明確編輯／儲存／取消；側邊按鈕簡化為「儲存專案」。提示文字仍以圈圈 i 點擊顯示。
- 測試可用 `BASS_TEST_PYTHON` 指定現有 Python。若本機另裝的外部 ffmpeg 轉檔逾時，可設 `BASS_TEST_SKIP_FLAC=1` 明確跳過該額外測項，其餘原生播放及首音／和聲測試照常執行。
- 已補入 A–B／名稱草稿、真正 Python 快取恢復及介面／OSMD 點擊橋接測試。預設以 unit test 為主；以 `BASS_TEST_INTEGRATION=1` 納入真實播放／Worker 整合測試，以 `BASS_TEST_UI=1 ./test.sh` 納入介面測試，或單獨執行 `./test-ui.sh`。


## 無譜全曲格線與全曲分析

- 匯入音源後，無譜格線依原曲長度延伸至結尾，切換短 stem 不會縮短全曲小節。共用「速度與時間對齊」提供 BPM、拍號與唯一的第一小節起點；手動修改全部暫存，右下角一次套用。起點前視為前奏；拍號需人工設定，最後一小節可不完整。
- 新建專案首次成功匯入原音後自動估測並設定可用建議 BPM；低品質／拍點不足保留目前速度。既有專案開啟／再匯入、追加 stem 不自動估測，手動重估不覆蓋校準。最多三個候選按鈕點選後填入共用草稿，與人工輸入、拍號及起點一起套用；Enter 同樣套用整區，不另有 BPM 勾選。數值與拍點定位收進資訊彈窗。估測只看開頭最多 90 秒，不代表拍號或小節第一拍；變速曲可繼續用時間錨點校準。
- 只有變更拍號才重建格線並把舊區間與人工標註存入歷史，保留時間錨點；純改 BPM／起點保留區間 ID，可用一次復原返回整批修改；匯入完整譜也保留無譜時的標註歷史，不猜測跨版本對應。
- 「分析全曲／續跑」逐區間分批處理首音與和聲，每批最多 24 區間／90 秒，顯示進度且可取消，完成結果逐筆保存。再次按下僅續跑尚無相同來源、時間及方法結果的區間；右鍵選「重新分析全曲」可強制重算（仍可使用有效 DSP 快取）。
- 來源未涵蓋的區間會明列，單區間過長或不足 0.15 秒也不假稱已分析。人工標註、三種鎖定及鎖定空白均保持。全曲不生成巨大能量圖；要查看某段音高能量，仍按「分析目前範圍」，之後可從快取恢復。
- 測試預設執行 `./test.sh`；目前機器可用 `BASS_TEST_PYTHON="$PWD/build/Bass Harmony Workbench T07 Unified.app/Contents/Resources/python/bin/python3.12" PYTHONDONTWRITEBYTECODE=1 ./test.sh`。`./test-tempo-workflow.sh` 為原生匯入／候選流程，設定 BASS_WORKER_PYTHON 與 BASS_WORKER_SCRIPT 後加 `--real` 才使用真正 Worker。介面 `./test-ui.sh --no-playback` 明確略過實際播放。


## 節拍器與預備拍

節拍器與預備拍已加入固定播放列：播放鍵旁 metronome 圖示切換節拍器，綠色表示開啟；「音量」彈窗分別調整音源（0～100%）與拍音（0～150%），無預備或 1～3 小節另行選擇。預備即使在節拍器關閉時也會打拍；期間顯示「預備中」，結束後從原位置起播，A–B 回跳不重做。暫停、定位、分析或預備中變速可取消；偏好隨專案保存。6/8 先敲六個八分音符、首拍重音；依目前校準，不會自動辨識正確第一拍。慢速預備前有短暫靜音暖機。

`./test-metronome.sh --model-only` 是純計算；不加參數包含真正離線渲染，`--live` 另測輸出裝置。

## 對齊偏移與速度漂移

- 中央「速度與時間對齊」可就地收合。BPM、拍號與第一小節起點共用右下角的套用／取消；±0.01／±0.1 秒微調也只改草稿。起點是最終主時間，已包含原先整體偏移的效果，既有錨點一起平移；聲音素材的偏移另在進階欄位管理，仍由同一按鈕套用。
- 若前段對不上、中段碰巧對上、後段又偏，應同時校正起點與速度。展開「兩點校正速度與起點」，選兩個相距較遠、能在原音確認的小節起點，輸入實際秒數；也可點波形定位後取游標。填入後選用兩點校正，主欄位預覽換算的 BPM／起點；按整區「套用」才取代舊錨點與速度，可復原。
- 校正點 A、B 與循環 A–B 各自獨立。展開校正區時暫緩播放跟隨，避免操作中換小節；關閉後恢復。
- 多個時間錨點會決定區段速度，因此 BPM 欄位停用；可用兩點重新校正，或在同一草稿清除錨點再修改 BPM，最後一起套用。變速曲仍可增加手動錨點。
- 調整對齊會保留人工資料與區間身份，自動結果需依新時間更新。請核對前、中、後至少三處；不能只看某一拍剛好對上。
- 能量圖綠線是小節起點，灰線是四分音符拍線。CQT 低頻窗口較長，亮色邊緣不是精準 onset；請以波形、清楚起音與原音核對。播放游標使用音訊引擎來源 sampleTime，約每 35 ms 更新畫面；這不是聲音輸出裝置延遲的實測保證。

## 可選 BPM 模型

「速度與時間對齊」可選 librosa 或 Beat This! small0（CPU）。首次預設 librosa；成功估測產生候選後記住模型，新專案首次匯入與下次開啟 app 會沿用。模型不可用時明示暫用 librosa；人工校準與整區套用規則不變。small0 拍層級不一致時仍需人工確認，不保證每首歌曲的全曲 BPM。

small0 使用 app 外獨立環境與本機權重，一次估測完成／取消即結束程序。基本 app 不含 torch，不會自動下載模型；模型商店與完整安裝管理暫不提供。
