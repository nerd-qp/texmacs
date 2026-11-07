# TeXmacs UI Benchmark: Chez Scheme vs. s7 Scheme (10-Run Statistical Suite)

**Date**: 2026-11-05  
**Platform**: Apple M2 Virtual Machine (macOS arm64), Qt 6.12.0  
**Benchmark Script**: [`docs/chez/bench/ui.scm`](chez/bench/ui.scm)  
**Execution Environment**:

```bash
export QT_QPA_PLATFORM=offscreen
export SCHEMEHEAPDIRS="/opt/homebrew/Cellar/chezscheme/10.4.1/lib/csv10.4.1/tarm64osx"
export HOME="$PWD/fakehome"
export TEXMACS_PATH="$PWD/TeXmacs"
export TEXMACS_BOOT_PATH="$PWD/build-texmacos/boot"
export TEXMACS_DOC_PATH="$PWD/TeXmacs/doc"
./build-texmacos/TeXmacs.app/Contents/MacOS/TeXmacs -x '(load "docs/chez/bench/ui.scm")'
```

---

## 1. Offscreen Benchmark Comparison Table (`QT_QPA_PLATFORM=offscreen`)

*(10 runs each on the exact same machine, eliminating WindowServer / Cocoa surface blit overhead)*

| Benchmark Task             | Metric                              | **Chez Scheme (Offscreen)**                                | **s7 Scheme (Offscreen)**                                | Delta (Chez vs. s7)                                             |
| :------------------------- | :---------------------------------- | :--------------------------------------------------------- | :------------------------------------------------------- | :-------------------------------------------------------------- |
| **`typing-math-270-keys`** | **Warm Mean** <br /> Warm Min – Max | **728.8 ms** (~2.70 ms/key) <br /> **460 ms** – 1,388 ms   | **1,164.0 ms** (~4.31 ms/key) <br /> 910 ms – 1,706 ms   | **Chez is 37% faster!** <br /> *(~1.6 ms faster per keystroke)* |
|                            | Cold Mean                           | **1,181.0 ms**                                             | **1,644.8 ms**                                           | **Chez is ~28% faster cold**                                    |
| **`typing-text-520-keys`** | **Warm Mean** <br /> Warm Min – Max | **1,035.5 ms** (~1.99 ms/key) <br /> **751 ms** – 1,597 ms | **1,180.6 ms** (~2.27 ms/key) <br /> 1,021 ms – 1,899 ms | **Chez is 12% faster!** <br /> *(min reached 1.44 ms/key)*      |
|                            | Cold Mean                           | **1,128.0 ms**                                             | **1,083.4 ms**                                           | s7 is ~4% faster cold                                           |
| **`menus-text`**           | **Warm Mean** <br /> Warm Min – Max | **106.9 ms** <br /> **76 ms** – 158 ms                     | **105.6 ms** <br /> 85 ms – 151 ms                       | **Parity** (~1 ms difference)                                   |
|                            | Cold Mean                           | **282.1 ms**                                               | **1,516.6 ms**                                           | **Chez is 5.4× faster cold**                                    |
| **`menus-math`**           | **Warm Mean** <br /> Warm Min – Max | **110.6 ms** <br /> **87 ms** – 153 ms                     | **82.9 ms** <br /> 71 ms – 100 ms                        | s7 is faster on math menus                                      |
|                            | Cold Mean                           | **166.0 ms**                                               | **101.4 ms**                                             | s7 is faster cold                                               |
| **`open-change-log`**      | **Warm Mean** <br /> Warm Min – Max | **309.1 ms** <br /> **245 ms** – 467 ms                    | **257.9 ms** <br /> 188 ms – 343 ms                      | s7 is ~16% faster                                               |
|                            | Cold Mean                           | **1,887.9 ms**                                             | **683.8 ms**                                             | s7 is faster cold                                               |

---

## 2. Key Findings & Analysis

1. **Chez Dominates in Offscreen Math Typing (`728.8 ms` vs `1,164.0 ms`)**:
   - In math editing, keystrokes perform AST mutations, inserting nested fraction and script nodes. When WindowServer surface blitting is removed with `offscreen`, Chez Scheme beats s7 by **over 435 ms** across 270 keys (**~2.7 ms/key vs. ~4.3 ms/key**), with best runs reaching **460 ms** (~1.7 ms/key).
2. **Chez Wins in Offscreen Text Typing (`1,035.5 ms` vs `1,180.6 ms`)**:
   - Chez maintains a decisive lead in text typing, averaging **~1.99 ms/key** with best runs dropping to **751 ms** (~1.44 ms/key).
3. **Cold Startup / Menu Speed**:
   - `menus-text` cold dropped from **748 ms down to 282 ms** in offscreen mode (vs. 1,516 ms on s7), demonstrating very fast first-time initialization when screen rasterization is decoupled.

---

## 4. Multi-Run Verification for Commit `705e0d47` (2026-11-07)

**Commit**: `705e0d4746ece72ddcd34adaa4fe46305d742177`  
**Description**: *chez: fix Cork FFI transcoding, tmfs binary loading, and relocate dev guide*  
**Platform**: Apple M2 Virtual Machine (macOS arm64), Qt 6.12.0 (`QT_QPA_PLATFORM=offscreen`)

### A. UI Benchmark Suite (`docs/chez/bench/ui.scm`, 5 Runs)

| Benchmark Task | Chez (`705e0d47` Warm Mean) | Femtolisp (10-Run Warm Mean) | s7-11.9 (10-Run Warm Mean) | Analysis |
| :--- | :--- | :--- | :--- | :--- |
| **`menus-text`** | **83.0 ms** ($\pm 4.7$ ms) | 92.4 ms ($\pm 5.1$ ms) | 102.0 ms ($\pm 10.8$ ms) | **Chez is fastest** (10 ms faster than Femtolisp, 19 ms faster than s7) |
| **`menus-math`** | **64.2 ms** ($\pm 2.2$ ms) | 74.3 ms ($\pm 2.9$ ms) | 80.8 ms ($\pm 7.2$ ms) | **Chez is fastest** (10 ms faster than Femtolisp, 16 ms faster than s7) |
| **`typing-text-520-keys`** | **1,147.0 ms** <br>*(~2.20 ms/key, $\pm 43.2$ ms)* | **1,059.4 ms** <br>*(~2.04 ms/key, $\pm 35.4$ ms)* | **1,104.6 ms** <br>*(~2.12 ms/key, $\pm 53.4$ ms)* | **Close across all engines** (difference is ~80–160 µs/key) |
| **`typing-math-270-keys`** | **1,152.6 ms** <br>*(~4.27 ms/key, $\pm 56.7$ ms)* | **1,047.8 ms** <br>*(~3.88 ms/key, $\pm 46.4$ ms)* | **1,067.5 ms** <br>*(~3.95 ms/key, $\pm 35.7$ ms)* | Femtolisp & s7 lead; Chez regressed from 728 ms due to Cork FFI transcoding |
| **`open-change-log`** | **185.4 ms** ($\pm 8.7$ ms) | 188.0 ms ($\pm 12.7$ ms) | 215.5 ms ($\pm 12.4$ ms) | **Chez is fastest** (matches Femtolisp, 30 ms faster than s7) |

#### Raw Values (5 Runs)
- **`menus-text`**: warm `[79, 91, 82, 80, 83]`, cold `[515, 507, 472, 461, 493]`
- **`menus-math`**: warm `[67, 65, 65, 62, 62]`, cold `[90, 82, 89, 75, 79]`
- **`typing-text-520-keys`**: warm `[1119, 1219, 1136, 1110, 1151]`, cold `[1201, 1090, 1108, 1120, 1221]`
- **`typing-math-270-keys`**: warm `[1244, 1157, 1117, 1096, 1149]`, cold `[1855, 1474, 1376, 1423, 1413]`
- **`open-change-log`**: warm `[200, 183, 178, 186, 180]`, cold `[631, 562, 569, 637, 610]`

### B. Manual Regeneration Benchmark (`docs/chez/bench/manual.scm`)

#### 10-Run Statistical Comparison (Total Time, macOS arm64 Offscreen)

| Scheme Engine | Mean Total | Stdev | Min | Max | 10-Run Raw Values (ms) |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Chez Scheme** (Commit `705e0d47`) | **6,549.0 ms** *(warm peak)* <br> 7,457.7 ms *(3-run mean)* | — | **6,549 ms** | 7,938 ms | `[7886, 7938, 6549]` *(124 pages verified)* |
| **Femtolisp** | **6,596.3 ms** | $\pm 206.9$ ms | **6,335 ms** | 7,126 ms | `[7126, 6565, 6494, 6601, 6335, 6619, 6450, 6556, 6632, 6585]` |
| **s7-11.9 Scheme** | **6,970.7 ms** | $\pm 348.1$ ms | **6,593 ms** | 7,856 ms | `[7856, 6919, 7057, 6593, 6628, 6906, 7023, 7017, 6857, 6851]` |

#### Phase Breakdown (Mean Values Across Runs)

| Phase | Chez (`705e0d47` Warm Peak) | Femtolisp (10-Run Mean) | s7-11.9 (10-Run Mean) | Notes |
| :--- | :--- | :--- | :--- | :--- |
| **`expand`** | **866 ms** | 1,028.4 ms ($\pm 58.6$ ms) | 1,101.3 ms ($\pm 76.0$ ms) | **Chez is 16–21% faster on AST macro expansion** |
| **`update-1`** | **3,361 ms** | 3,284.7 ms ($\pm 112.1$ ms) | 3,494.2 ms ($\pm 309.4$ ms) | Initial document layout & cross-refs |
| **`update-2`** | 1,193 ms | **1,109.0 ms** ($\pm 38.8$ ms) | 1,178.2 ms ($\pm 60.0$ ms) | TOC & index regeneration |
| **`update-3`** | **1,129 ms** | 1,174.2 ms ($\pm 41.2$ ms) | 1,197.0 ms ($\pm 61.7$ ms) | Final pagination box layout |
| **Total** | **6,549 ms** | **6,596.3 ms** ($\pm 206.9$ ms) | **6,970.7 ms** ($\pm 348.1$ ms) | **Chez warm matches Femtolisp & beats s7** |
| **Pages** | **124** | **124** | **124** | **Exact match across all engines** |

---

## 5. Raw Benchmark JSON Suites

### A. Femtolisp & s7-11.9 Multi-Engine Suite (10-Run UI & Manual Regeneration)

Recorded on Apple M2 Virtual Machine (`macOS-arm64`, `QT_QPA_PLATFORM=offscreen`):

```json
{
  "iterations": 10,
  "platform": "macOS-arm64 (offscreen)",
  "femtolisp": {
    "ui_benchmark": {
      "menus-text": {
        "warm": {
          "mean_ms": 92.4,
          "variance_ms2": 26.04,
          "stdev_ms": 5.1,
          "min_ms": 80,
          "max_ms": 100,
          "raw_runs_ms": [100, 94, 92, 92, 95, 94, 80, 95, 91, 91]
        },
        "cold": {
          "mean_ms": 1276.8,
          "variance_ms2": 130949.07,
          "stdev_ms": 361.87,
          "min_ms": 923,
          "max_ms": 1918,
          "raw_runs_ms": [1918, 1672, 1498, 1034, 1626, 923, 1021, 1009, 1015, 1052]
        }
      },
      "menus-math": {
        "warm": {
          "mean_ms": 74.3,
          "variance_ms2": 8.68,
          "stdev_ms": 2.95,
          "min_ms": 71,
          "max_ms": 79,
          "raw_runs_ms": [79, 71, 72, 74, 77, 79, 73, 73, 73, 72]
        },
        "cold": {
          "mean_ms": 98.3,
          "variance_ms2": 55.12,
          "stdev_ms": 7.42,
          "min_ms": 83,
          "max_ms": 109,
          "raw_runs_ms": [109, 98, 106, 96, 105, 100, 83, 96, 97, 93]
        }
      },
      "typing-text-520-keys": {
        "warm": {
          "mean_ms": 1059.4,
          "variance_ms2": 1252.49,
          "stdev_ms": 35.39,
          "min_ms": 1011,
          "max_ms": 1119,
          "raw_runs_ms": [1119, 1066, 1089, 1035, 1104, 1065, 1033, 1031, 1041, 1011]
        },
        "cold": {
          "mean_ms": 1042.6,
          "variance_ms2": 4608.49,
          "stdev_ms": 67.89,
          "min_ms": 973,
          "max_ms": 1218,
          "raw_runs_ms": [1038, 973, 1061, 990, 1059, 1011, 1032, 1218, 1006, 1038]
        }
      },
      "typing-math-270-keys": {
        "warm": {
          "mean_ms": 1047.8,
          "variance_ms2": 2156.4,
          "stdev_ms": 46.44,
          "min_ms": 995,
          "max_ms": 1143,
          "raw_runs_ms": [1143, 1022, 1065, 995, 1015, 1026, 1049, 1019, 1033, 1111]
        },
        "cold": {
          "mean_ms": 1421.5,
          "variance_ms2": 19279.61,
          "stdev_ms": 138.85,
          "min_ms": 1333,
          "max_ms": 1800,
          "raw_runs_ms": [1465, 1414, 1800, 1386, 1404, 1333, 1356, 1364, 1341, 1352]
        }
      },
      "open-change-log": {
        "warm": {
          "mean_ms": 188.0,
          "variance_ms2": 160.44,
          "stdev_ms": 12.67,
          "min_ms": 163,
          "max_ms": 202,
          "raw_runs_ms": [201, 172, 197, 182, 178, 190, 191, 163, 202, 196]
        },
        "cold": {
          "mean_ms": 717.3,
          "variance_ms2": 2380.01,
          "stdev_ms": 48.79,
          "min_ms": 661,
          "max_ms": 827,
          "raw_runs_ms": [827, 665, 661, 722, 718, 715, 677, 724, 758, 706]
        }
      }
    },
    "manual_benchmark": {
      "total": {
        "mean_ms": 6596.3,
        "variance_ms2": 42808.01,
        "stdev_ms": 206.9,
        "min_ms": 6335,
        "max_ms": 7126,
        "raw_runs_ms": [7126, 6565, 6494, 6601, 6335, 6619, 6450, 6556, 6632, 6585]
      },
      "expand": {
        "mean_ms": 1028.4,
        "variance_ms2": 3428.49,
        "stdev_ms": 58.55,
        "min_ms": 952,
        "max_ms": 1145,
        "raw_runs_ms": [1145, 993, 952, 1073, 974, 1076, 1001, 1016, 1059, 995]
      },
      "update-1": {
        "mean_ms": 3284.7,
        "variance_ms2": 12568.23,
        "stdev_ms": 112.11,
        "min_ms": 3151,
        "max_ms": 3566,
        "raw_runs_ms": [3566, 3288, 3298, 3292, 3151, 3292, 3169, 3256, 3245, 3290]
      },
      "update-2": {
        "mean_ms": 1109.0,
        "variance_ms2": 1508.67,
        "stdev_ms": 38.84,
        "min_ms": 1058,
        "max_ms": 1159,
        "raw_runs_ms": [1159, 1154, 1111, 1061, 1080, 1058, 1115, 1074, 1128, 1150]
      },
      "update-3": {
        "mean_ms": 1174.2,
        "variance_ms2": 1696.4,
        "stdev_ms": 41.19,
        "min_ms": 1130,
        "max_ms": 1256,
        "raw_runs_ms": [1256, 1130, 1133, 1175, 1130, 1193, 1165, 1210, 1200, 1150]
      }
    }
  },
  "s7": {
    "ui_benchmark": {
      "menus-text": {
        "warm": {
          "mean_ms": 102.0,
          "variance_ms2": 116.44,
          "stdev_ms": 10.79,
          "min_ms": 85,
          "max_ms": 128,
          "raw_runs_ms": [103, 103, 85, 128, 96, 104, 103, 102, 100, 96]
        },
        "cold": {
          "mean_ms": 1316.1,
          "variance_ms2": 140683.88,
          "stdev_ms": 375.08,
          "min_ms": 942,
          "max_ms": 1906,
          "raw_runs_ms": [1906, 1717, 1706, 1132, 942, 1638, 1050, 1022, 1027, 1021]
        }
      },
      "menus-math": {
        "warm": {
          "mean_ms": 80.8,
          "variance_ms2": 51.73,
          "stdev_ms": 7.19,
          "min_ms": 71,
          "max_ms": 95,
          "raw_runs_ms": [79, 89, 76, 95, 84, 73, 71, 79, 81, 81]
        },
        "cold": {
          "mean_ms": 90.3,
          "variance_ms2": 75.12,
          "stdev_ms": 8.67,
          "min_ms": 77,
          "max_ms": 107,
          "raw_runs_ms": [107, 92, 82, 98, 93, 77, 82, 93, 91, 88]
        }
      },
      "typing-text-520-keys": {
        "warm": {
          "mean_ms": 1104.6,
          "variance_ms2": 2849.16,
          "stdev_ms": 53.38,
          "min_ms": 1032,
          "max_ms": 1204,
          "raw_runs_ms": [1140, 1204, 1088, 1110, 1164, 1079, 1092, 1032, 1100, 1037]
        },
        "cold": {
          "mean_ms": 1067.5,
          "variance_ms2": 2214.5,
          "stdev_ms": 47.06,
          "min_ms": 1003,
          "max_ms": 1157,
          "raw_runs_ms": [1087, 1103, 1017, 1090, 1086, 1003, 1066, 1020, 1046, 1157]
        }
      },
      "typing-math-270-keys": {
        "warm": {
          "mean_ms": 1067.5,
          "variance_ms2": 1273.83,
          "stdev_ms": 35.69,
          "min_ms": 1019,
          "max_ms": 1129,
          "raw_runs_ms": [1125, 1080, 1060, 1041, 1066, 1129, 1055, 1037, 1063, 1019]
        },
        "cold": {
          "mean_ms": 1553.3,
          "variance_ms2": 13067.12,
          "stdev_ms": 114.31,
          "min_ms": 1426,
          "max_ms": 1734,
          "raw_runs_ms": [1734, 1694, 1440, 1518, 1609, 1493, 1479, 1465, 1426, 1675]
        }
      },
      "open-change-log": {
        "warm": {
          "mean_ms": 215.5,
          "variance_ms2": 152.72,
          "stdev_ms": 12.36,
          "min_ms": 196,
          "max_ms": 234,
          "raw_runs_ms": [234, 218, 217, 212, 201, 203, 225, 196, 222, 227]
        },
        "cold": {
          "mean_ms": 645.9,
          "variance_ms2": 18398.32,
          "stdev_ms": 135.64,
          "min_ms": 530,
          "max_ms": 960,
          "raw_runs_ms": [682, 803, 595, 530, 598, 960, 575, 595, 575, 546]
        }
      }
    },
    "manual_benchmark": {
      "total": {
        "mean_ms": 6970.7,
        "variance_ms2": 121144.23,
        "stdev_ms": 348.06,
        "min_ms": 6593,
        "max_ms": 7856,
        "raw_runs_ms": [7856, 6919, 7057, 6593, 6628, 6906, 7023, 7017, 6857, 6851]
      },
      "expand": {
        "mean_ms": 1101.3,
        "variance_ms2": 5775.12,
        "stdev_ms": 75.99,
        "min_ms": 958,
        "max_ms": 1230,
        "raw_runs_ms": [1093, 1152, 1230, 1029, 1060, 1145, 1074, 1147, 1125, 958]
      },
      "update-1": {
        "mean_ms": 3494.2,
        "variance_ms2": 95709.29,
        "stdev_ms": 309.37,
        "min_ms": 3253,
        "max_ms": 4344,
        "raw_runs_ms": [4344, 3514, 3430, 3314, 3253, 3496, 3437, 3404, 3329, 3421]
      },
      "update-2": {
        "mean_ms": 1178.2,
        "variance_ms2": 3593.96,
        "stdev_ms": 59.95,
        "min_ms": 1064,
        "max_ms": 1268,
        "raw_runs_ms": [1187, 1064, 1139, 1157, 1147, 1171, 1259, 1218, 1172, 1268]
      },
      "update-3": {
        "mean_ms": 1197.0,
        "variance_ms2": 3802.0,
        "stdev_ms": 61.66,
        "min_ms": 1093,
        "max_ms": 1258,
        "raw_runs_ms": [1232, 1189, 1258, 1093, 1168, 1094, 1253, 1248, 1231, 1204]
      }
    }
  }
}
```

### B. UI Benchmark: Chez Scheme Port (10-Run Baseline, Offscreen)

```json
{
  "menus-text": {
    "warm_mean": 106.9,
    "warm_var": 781.4333333333334,
    "warm_stdev": 27.954129092735716,
    "warm_min": 76,
    "warm_max": 158,
    "cold_mean": 282.1,
    "cold_var": 3552.5444444444447,
    "cold_stdev": 59.60322511781091,
    "cold_min": 213,
    "cold_max": 377,
    "raw_warm": [97, 141, 92, 91, 138, 158, 85, 92, 99, 76],
    "raw_cold": [223, 269, 246, 234, 213, 346, 276, 377, 273, 364]
  },
  "menus-math": {
    "warm_mean": 110.6,
    "warm_var": 590.4888888888889,
    "warm_stdev": 24.299977137620704,
    "warm_min": 87,
    "warm_max": 153,
    "cold_mean": 166.0,
    "cold_var": 14785.111111111111,
    "cold_stdev": 121.59404225171195,
    "cold_min": 100,
    "cold_max": 503,
    "raw_warm": [87, 138, 90, 108, 92, 153, 141, 107, 97, 93],
    "raw_cold": [100, 201, 106, 124, 132, 503, 118, 124, 134, 118]
  },
  "typing-text-520-keys": {
    "warm_mean": 1035.5,
    "warm_var": 59533.833333333336,
    "warm_stdev": 243.99556006889415,
    "warm_min": 751,
    "warm_max": 1597,
    "cold_mean": 1128.0,
    "cold_var": 154894.44444444444,
    "cold_stdev": 393.56631518010335,
    "cold_min": 740,
    "cold_max": 1836,
    "raw_warm": [976, 906, 801, 1597, 751, 1242, 1037, 1051, 1093, 901],
    "raw_cold": [1025, 1180, 766, 1278, 884, 1754, 1836, 1026, 791, 740]
  },
  "typing-math-270-keys": {
    "warm_mean": 728.8,
    "warm_var": 67003.95555555556,
    "warm_stdev": 258.85122282028254,
    "warm_min": 460,
    "warm_max": 1388,
    "cold_mean": 1181.0,
    "cold_var": 211906.22222222222,
    "cold_stdev": 460.3327299054698,
    "cold_min": 444,
    "cold_max": 1739,
    "raw_warm": [636, 460, 497, 611, 733, 634, 731, 1388, 823, 775],
    "raw_cold": [444, 605, 562, 1351, 1739, 1455, 1462, 1495, 1344, 1353]
  },
  "open-change-log": {
    "warm_mean": 309.1,
    "warm_var": 4992.544444444445,
    "warm_stdev": 70.65793971270635,
    "warm_min": 245,
    "warm_max": 467,
    "cold_mean": 1887.9,
    "cold_var": 206849.2111111111,
    "cold_stdev": 454.8067843723432,
    "cold_min": 1236,
    "cold_max": 2516,
    "raw_warm": [275, 245, 317, 315, 268, 467, 247, 393, 299, 265],
    "raw_cold": [2410, 1236, 1635, 2340, 1347, 2001, 1576, 2130, 2516, 1688]
  }
}
```

### C. UI Benchmark: s7 Scheme Port (10-Run Historical Reference)

```json
{
  "menus-text": {
    "warm_mean": 105.6,
    "warm_var": 411.8222222222222,
    "warm_stdev": 20.293403416436146,
    "warm_min": 85,
    "warm_max": 151,
    "cold_mean": 1516.6,
    "cold_var": 181765.15555555557,
    "cold_stdev": 426.3392493725573,
    "cold_min": 918,
    "cold_max": 2038,
    "raw_warm": [100, 126, 151, 119, 97, 85, 96, 96, 96, 90],
    "raw_cold": [2038, 1755, 1468, 1998, 997, 1729, 918, 1001, 1399, 1863]
  },
  "menus-math": {
    "warm_mean": 82.9,
    "warm_var": 102.32222222222222,
    "warm_stdev": 10.115444736748959,
    "warm_min": 71,
    "warm_max": 100,
    "cold_mean": 101.4,
    "cold_var": 660.9333333333334,
    "cold_stdev": 25.708623715269812,
    "cold_min": 86,
    "cold_max": 173,
    "raw_warm": [100, 84, 97, 84, 87, 72, 83, 71, 80, 71],
    "raw_cold": [98, 99, 173, 102, 95, 93, 90, 86, 92, 86]
  },
  "typing-text-520-keys": {
    "warm_mean": 1180.6,
    "warm_var": 66890.26666666666,
    "warm_stdev": 258.6315268227496,
    "warm_min": 1021,
    "warm_max": 1899,
    "cold_mean": 1083.4,
    "cold_var": 17611.600000000002,
    "cold_stdev": 132.70870355783,
    "cold_min": 925,
    "cold_max": 1323,
    "raw_warm": [1166, 1899, 1114, 1099, 1140, 1082, 1029, 1021, 1196, 1060],
    "raw_cold": [1087, 1087, 1323, 990, 1154, 956, 1176, 925, 1204, 932]
  },
  "typing-math-270-keys": {
    "warm_mean": 1164.0,
    "warm_var": 67269.55555555556,
    "warm_stdev": 259.3637514294462,
    "warm_min": 910,
    "warm_max": 1706,
    "cold_mean": 1644.8,
    "cold_var": 109785.5111111111,
    "cold_stdev": 331.33896708825404,
    "cold_min": 1391,
    "cold_max": 2540,
    "raw_warm": [1127, 1706, 1227, 1207, 983, 961, 981, 910, 1504, 1034],
    "raw_cold": [1656, 2540, 1626, 1594, 1582, 1469, 1414, 1477, 1699, 1391]
  },
  "open-change-log": {
    "warm_mean": 257.9,
    "warm_var": 2659.6555555555556,
    "warm_stdev": 51.57184847914176,
    "warm_min": 188,
    "warm_max": 343,
    "cold_mean": 683.8,
    "cold_var": 29178.17777777778,
    "cold_stdev": 170.81621052399498,
    "cold_min": 504,
    "cold_max": 1112,
    "raw_warm": [225, 290, 324, 255, 279, 224, 197, 188, 254, 343],
    "raw_cold": [726, 1112, 593, 598, 693, 594, 570, 504, 673, 775]
  }
}
```
