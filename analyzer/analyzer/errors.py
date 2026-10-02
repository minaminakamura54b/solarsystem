"""終了コードに対応する例外。CLI（__main__.py）がこれを捕まえて終了コードと出力 JSON に変える。"""

EXIT_OK = 0
EXIT_ERROR = 1
EXIT_NO_TEMPERATURE = 2
EXIT_NO_GRID = 3
EXIT_INSUFFICIENT_BASELINE = 4


class AnalyzerError(Exception):
    exit_code = EXIT_ERROR
    status = "failed"

    def __init__(self, reason: str, message: str):
        super().__init__(message)
        self.reason = reason
        self.message = message


class NoTemperatureDataError(AnalyzerError):
    """温度データ（放射温度）を取得できない。推定や色からの逆算はしない。"""

    exit_code = EXIT_NO_TEMPERATURE
    status = "needs_review"


class GridError(AnalyzerError):
    """解析に使うグリッドが無い、またはグリッドを提案できない。"""

    exit_code = EXIT_NO_GRID
    status = "needs_review"


class InsufficientBaselineError(AnalyzerError):
    """基準温度を出すための正常パネルが足りない。"""

    exit_code = EXIT_INSUFFICIENT_BASELINE
    status = "needs_review"
