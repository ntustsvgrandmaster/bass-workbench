# Worker 通訊入口：每行一個 JSON，標準輸出只供協定；錯誤 traceback 放標準錯誤。

"""JSON Lines worker. Local files only; no network clients and no model downloads."""
import json
import sys
import traceback

# allow_nan=False 避免把 NaN 寫進 Swift 無法正常解碼的結果；flush 讓進度即時傳出。
def emit(value):
    print(json.dumps(value, ensure_ascii=False, allow_nan=False), flush=True)

def dispatch(request):
    from analysis import feature_job, harmony_job, tempo_job
    request_id = request["id"]
    def progress(value, message):
        emit(dict(id=request_id, type="progress", progress=value, message=message))
    op = request["op"]
    if op == "features":
        return feature_job(request, progress)
    if op == "harmony":
        return harmony_job(request, progress)
    if op == "tempo":
        return tempo_job(request, progress)
    if op == "ping":
        import librosa, numpy, platform
        return dict(librosa=librosa.__version__, numpy=numpy.__version__, arch=platform.machine(), network=False)
    raise ValueError("Unknown local analysis operation")

# 程序常駐，讓多個區間共用已載入的函式；取消由 Swift 終止程序，重試時重新啟動。
for line in sys.stdin:
    request = None
    try:
        request = json.loads(line)
        result = dispatch(request)
        emit(dict(id=request["id"], type="result", result=result))
    except Exception as error:
        emit(dict(id=request.get("id", "") if request else "", type="error", message=str(error)))
        traceback.print_exc(file=sys.stderr)
