/**
 * SVG icon used to represent the AI feature across the editor (formatting
 * toolbar AI button, slash menu "Ask AI" item, drag-handle "Ask AI" item).
 *
 * Design: a 4-point sparkle with a smaller accent sparkle. Inherits color via
 * `currentColor`, so callers can drive it with CSS `color` on a parent.
 */

export interface AIIconProps {
  size?: number;
  className?: string;
  style?: React.CSSProperties;
}

export function AIIcon({ size = 16, className, style }: AIIconProps) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="currentColor"
      aria-hidden="true"
      className={className}
      style={style}
    >
      {/* single symmetric 4-point sparkle — renders cleanly at all sizes */}
      <path d="M12 2.5 L13.85 9.65 L21 11.5 L13.85 13.35 L12 20.5 L10.15 13.35 L3 11.5 L10.15 9.65 Z" />
    </svg>
  );
}
