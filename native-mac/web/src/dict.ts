// Minimal i18n for strings BlockNote doesn't cover (our custom slash item
// + the empty-state in LiquidGlassSlashMenu).  BlockNote's own dictionary
// handles slash-menu defaults and formatting-toolbar tooltips.

export type AppLocale = "en" | "zh";

export interface AppDict {
  mathTitle: string;
  mathSubtext: string;
  aiTitle: string;
  aiSubtext: string;
  groupAdvanced: string;
  noResults: string;
}

const dicts: Record<AppLocale, AppDict> = {
  en: {
    mathTitle: "Math",
    mathSubtext: "LaTeX equation block ($$…$$)",
    aiTitle: "Ask AI",
    aiSubtext: "Rewrite the selection or generate text",
    groupAdvanced: "Advanced",
    noResults: "No results",
  },
  zh: {
    mathTitle: "数学公式",
    mathSubtext: "LaTeX 公式块（$$…$$）",
    aiTitle: "AI 助手",
    aiSubtext: "改写所选文本或生成内容",
    groupAdvanced: "高级",
    noResults: "没有结果",
  },
};

export function resolveLocale(code: string | undefined | null): AppLocale {
  if (!code) return "en";
  const lower = code.toLowerCase();
  if (lower === "zh" || lower.startsWith("zh-") || lower.startsWith("zh_")) {
    // Treat all Chinese variants as Simplified for now; we ship only zh.
    return "zh";
  }
  return "en";
}

export function getDict(locale: AppLocale): AppDict {
  return dicts[locale];
}
