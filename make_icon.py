#!/usr/bin/env python3
"""
Lachesis 앱 아이콘 생성기
- 짙은 슬레이트 배경의 둥근 사각형 (macOS 스타일)
- 사용량 진행 막대 3개 (하늘색 2개 + 경고 주황 1개)
스크린샷의 터미널 계기판 느낌을 아이콘으로 옮긴 디자인.
"""
from PIL import Image, ImageDraw, ImageFilter
import os

OUT = "Lachesis/Assets.xcassets/AppIcon.appiconset"
os.makedirs(OUT, exist_ok=True)

S = 1024
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

# ── 1) 배경: macOS 표준 비율의 둥근 사각형 (824x824, 모서리 반경 ~185)
MARGIN = 100
RADIUS = 185
rect = (MARGIN, MARGIN, S - MARGIN, S - MARGIN)

# 위->아래로 어두워지는 슬레이트 그라데이션
grad = Image.new("RGBA", (S, S), (0, 0, 0, 0))
top = (37, 40, 54)      # #252836
bottom = (20, 21, 30)   # #14151E
gdraw = ImageDraw.Draw(grad)
for y in range(MARGIN, S - MARGIN):
    t = (y - MARGIN) / (S - 2 * MARGIN)
    c = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)) + (255,)
    gdraw.line([(MARGIN, y), (S - MARGIN, y)], fill=c)

mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle(rect, RADIUS, fill=255)
img.paste(grad, (0, 0), mask)

draw = ImageDraw.Draw(img)

# (이전엔 둥근 사각형 전체 둘레에 흰 외곽선을 그렸는데,
#  어두운 배경의 알림·Finder에서 '테두리'로 보여 제거했습니다.)

# ── 2) 사용량 막대 3개
TRACK = (62, 84, 112, 255)       # 슬레이트 블루 트랙 (#3E5470)
BLUE = (148, 196, 245, 255)      # 하늘색 채움 (#94C4F5)
ORANGE = (242, 166, 90, 255)     # 한도 임박 주황 (#F2A65A)

bar_x0, bar_x1 = 232, 792
bar_h = 76
r = bar_h // 2
ys = [318, 474, 630]             # 세 막대의 세로 위치
fills = [(0.34, BLUE), (0.62, BLUE), (0.86, ORANGE)]

for y, (frac, color) in zip(ys, fills):
    # 트랙(바탕 막대)
    draw.rounded_rectangle((bar_x0, y, bar_x1, y + bar_h), r, fill=TRACK)
    # 채움 막대
    fill_w = int((bar_x1 - bar_x0) * frac)
    if fill_w > bar_h:  # 캡슐이 무너지지 않을 만큼만
        draw.rounded_rectangle((bar_x0, y, bar_x0 + fill_w, y + bar_h), r, fill=color)
        # 채움 끝에 살짝 밝은 점 (게이지 바늘 느낌)
        dot_x = bar_x0 + fill_w - r
        draw.ellipse((dot_x - 14, y + bar_h // 2 - 14, dot_x + 14, y + bar_h // 2 + 14),
                     fill=(255, 255, 255, 70))

# ── 3) 모든 크기로 저장
sizes = [16, 32, 64, 128, 256, 512, 1024]
for s in sizes:
    img.resize((s, s), Image.LANCZOS).save(f"{OUT}/icon_{s}.png")

print("아이콘 생성 완료:", ", ".join(str(s) for s in sizes))
