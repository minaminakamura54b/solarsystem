require "matrix"

# 単位正方形（0〜1）と四角形の間の射影変換（解析エンジンのグリッドと同じ対応: 左上・右上・右下・左下）
class Homography
  def self.unit_to_quad(quad)
    src = [ [ 0, 0 ], [ 1, 0 ], [ 1, 1 ], [ 0, 1 ] ]
    rows = []
    rhs = []
    src.zip(quad).each do |(x, y), (u, v)|
      rows << [ x, y, 1, 0, 0, 0, -u * x, -u * y ]
      rhs << u
      rows << [ 0, 0, 0, x, y, 1, -v * x, -v * y ]
      rhs << v
    end
    h = Matrix[*rows].inverse * Vector[*rhs]
    new(Matrix[[ h[0], h[1], h[2] ], [ h[3], h[4], h[5] ], [ h[6], h[7], 1.0 ]])
  rescue ExceptionForMatrix::ErrNotRegular
    nil
  end

  def initialize(matrix)
    @m = matrix
  end

  def point(x, y)
    w = @m[2, 0] * x + @m[2, 1] * y + @m[2, 2]
    [ (@m[0, 0] * x + @m[0, 1] * y + @m[0, 2]) / w, (@m[1, 0] * x + @m[1, 1] * y + @m[1, 2]) / w ]
  end

  # 四角形の中の点 → 単位正方形の中の位置
  def inverse_point(u, v)
    inv = @m.inverse
    w = inv[2, 0] * u + inv[2, 1] * v + inv[2, 2]
    return nil if w.abs < 1e-12

    [ (inv[0, 0] * u + inv[0, 1] * v + inv[0, 2]) / w, (inv[1, 0] * u + inv[1, 1] * v + inv[1, 2]) / w ]
  end
end
