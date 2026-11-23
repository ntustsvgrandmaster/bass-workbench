# Mint Groove — 公開 Demo

原創程序編曲與合成音源，供 Bass Harmony Workbench 操作示範。沒有使用私人歌曲、第三方取樣、SoundFont、模型或購買的樂譜。素材及生成程式採本資料夾的 [MIT 授權](LICENSE.txt)，可隨 GitHub 專案散布、修改與用於示範。

## 檔案

| 檔案 | 用途 |
|---|---|
| [mix.wav](mix.wav) | 完整混音，匯入為原曲 |
| [bass.wav](bass.wav) | 獨立合成 Bass，供聆聽及首音／基頻分析 |
| [harmony.wav](harmony.wav) | 獨立鍵盤和聲，供和弦候選分析 |
| [drums.wav](drums.wav) | 獨立合成鼓軌 |
| [bass.musicxml](bass.musicxml) | Bass 五線譜＋五弦 TAB，附和弦符號，可用 MuseScore 開啟 |
| [manifest.json](manifest.json) | 編曲音符、逐小節和弦、時間設定與素材 SHA-256 |
| [generate.py](generate.py) | 可重現的編曲、音訊與樂譜生成程式 |

這些 stem 是合成時的獨立聲部，並非從混音分離所得。

## 在工作台使用

1. 新建專案，將 `mix.wav` 匯入為原曲。
2. 匯入 `bass.musicxml` 作為參考譜，選五線譜或 TAB 核對。
3. 匯入三個 stem；Bass 分析來源選 `bass.wav`，和聲分析來源選 `harmony.wav`。
4. 確認速度 **120 BPM**、**4/4**、第一小節起點 **0.000 秒**，所有 stem 偏移 **0 秒**。自動估測的候選仍需核對。
5. 試播、設定 A–B、變速，並比較首音與 Root。例如第 2 小節是 **Am**，Bass 首音是 **C2**；第 4 小節是 **G**，Bass 首音是 **D2**。

全曲 16 小節、音樂長度 32 秒，加 0.5 秒尾端；無預備拍、無反覆記號。WAV 均為 44.1 kHz／16-bit／單聲道，長度相同且起點對齊。三個 stem 使用共用增益，逐樣本相加可重建混音（容許 PCM16 個別量化誤差）。

譜面包含四分／八分／附點音符、休止與頓音；五弦調弦 B0–E1–A1–D2–G2。五線譜以 Bass 慣例記高八度，MusicXML 設定實際發聲低八度；TAB 與五線譜為同一聲部的兩種表示。音訊的普通音符略縮短以保留起音，頓音更短；譜面時值仍是節奏佔位。

`manifest.json` 記錄生成時的編曲資料，並非模型分析結果。此組合成素材適合展示操作及對齊，不能用來代表真實演奏的音色或辨識準確率。尚需在實際 App 中人工試聽與驗收。

## 重新生成

使用已安裝 NumPy 的 Python 3（可沿用專案的分析環境）：

```sh
python3 demo/mint-groove/generate.py
```

不會下載任何素材。生成程式會覆寫本資料夾的四個 WAV、MusicXML 與 manifest。

## 素材檢查

在 Apple Silicon Mac 的專案根目錄執行：

```sh
zsh source/test-public-demo.sh
```

檢查使用工作台本身的 MusicXML 解析器及 AVFoundation，核對兩份譜表的時值／發聲音高／TAB、音訊長度／格式、stem 相加、削波與素材雜湊。通過不等於已完成實際 App 操作、MuseScore 顯示或人工音色驗收。
