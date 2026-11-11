import unittest

from repetition_cleanup import collapse_adjacent_repetitions as clean


class RepetitionCleanupTests(unittest.TestCase):
    def test_generic_three_and_four_restarts_keep_tail(self):
        for clause in ("需要重新检查配置", "如果文件已经保存", "A如果入了库"):
            for count in (3, 4, 7):
                with self.subTest(clause=clause, count=count):
                    source = "，".join([clause] * count) + "，请继续确认后续步骤。"
                    self.assertEqual(clean(source), clause + "，请继续确认后续步骤。")
                    self.assertEqual(source.count(clause), count)

    def test_following_question_does_not_block_neutral_restart(self):
        clause = "需要重新检查配置"
        self.assertEqual(clean("，".join([clause] * 3) + "，下一步怎么办？"), clause + "，下一步怎么办？")
        self.assertEqual(clean("，".join([clause] * 3) + "？"), "，".join([clause] * 3) + "？")
        self.assertEqual(clean("，".join([clause] * 3) + "！"), "，".join([clause] * 3) + "！")

    def test_keeps_final_punctuation(self):
        clause = "需要重新检查配置"
        self.assertEqual(clean("，".join([clause] * 4) + "。"), clause + "。")
        self.assertEqual(clean(",".join([clause] * 3) + ";"), clause + ";")

    def test_preserves_line_endings_and_trailing_whitespace(self):
        clause = "需要重新检查配置"
        for ending in ("\n", "\r\n", "\r", "  \n", "\t\r\n", "  "):
            with self.subTest(ending=ending):
                tail = "下一段要保留。" if ending.rstrip(" \t") else ""
                source = "，".join([clause] * 4) + ending + tail
                self.assertEqual(clean(source), clause + ending + tail)

    def test_two_repetitions_and_short_emphasis_unchanged(self):
        for text in ("需要重新检查配置，需要重新检查配置。", "很好，很好，很好，很好。",
                     "不要，不要，不要，不要！", "真的非常重要！真的非常重要！真的非常重要！"):
            self.assertEqual(clean(text), text)

    def test_quotes_and_code_unchanged(self):
        clause = "需要重新检查配置"
        repeated = "，".join([clause] * 4)
        for text in ("“" + repeated + "”", "他说：‘" + repeated + "’。",
                     "“引用开始\n" + repeated + "\n引用结束”", "`" + repeated + "`",
                     "```text\n" + repeated + "\n```", "data = [" + repeated + "]"):
            self.assertEqual(clean(text), text)

    def test_numeric_units_and_lists_unchanged(self):
        for clause in ("本次需要二十千克", "本次需要20千克", "20 kg", "二十", "千克", "平方米", "kilograms"):
            text = "，".join([clause] * 4) + "。"
            self.assertEqual(clean(text), text)
        repeated = "，".join(["需要重新检查配置"] * 4) + "。"
        for prefix in ("1. ", "１、", "一、", "- ", "* ", "• "):
            self.assertEqual(clean(prefix + repeated), prefix + repeated)
        lines = "\n".join(["需要重新检查配置"] * 4)
        self.assertEqual(clean(lines), lines)

    def test_different_clauses_and_word_internal_repetition_unchanged(self):
        for text in ("需要重新检查配置，需要重新检查配置文件，需要重新检查配置。",
                     "哈哈哈哈哈哈哈哈，妈妈看看这边。", "需要重新检查配置。需要重新检查配置。需要重新检查配置。",
                     "需要重新检查配置，需要重新检查配置，需要重新检查配置吗？"):
            self.assertEqual(clean(text), text)

    def test_colon_introduced_reference_blocks_are_preserved_until_blank_line(self):
        repeated = "，".join(["需要重新检查配置"] * 4) + "。"
        for text in ("原文：" + repeated, "内容如下：\n" + repeated + "\n仍属于内容。",
                     "payload:\r\n" + repeated):
            self.assertEqual(clean(text), text)
        text = "内容如下：\n" + repeated + "\n\n" + repeated
        self.assertEqual(clean(text), "内容如下：\n" + repeated + "\n\n需要重新检查配置。")

    def test_long_rejected_emphasis_run_is_preserved(self):
        text = "，".join(["需要重新检查配置"] * 10000) + "！"
        self.assertEqual(clean(text), text)

    def test_other_clauses_and_whitespace_survive(self):
        source = "前面的说明。 需要重新检查配置， 需要重新检查配置， 需要重新检查配置。后面的说明。\n"
        self.assertEqual(clean(source), "前面的说明。 需要重新检查配置。后面的说明。\n")
        self.assertEqual(clean(""), "")
        self.assertEqual(clean(" \n\t\r\n"), " \n\t\r\n")


if __name__ == "__main__":
    unittest.main()
