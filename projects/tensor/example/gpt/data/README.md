# The texts the tiny GPT trains on

- `names.txt` — 32,033 first names, one a line, from Andrej Karpathy's
  [makemore](https://github.com/karpathy/makemore) (MIT), which took them from US Social Security Administration
  records. Sorted by popularity, and alphabetically within each count — which is why `shuffledLines` exists.
- `shakespeare.txt` — "tiny Shakespeare", about a megabyte of the plays, from Karpathy's
  [char-rnn](https://github.com/karpathy/char-rnn). Shakespeare is in the public domain.
