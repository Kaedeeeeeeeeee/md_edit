// SF Symbols-style monochrome icons for the sidebar.
// All icons use currentColor so they tint with parent text color.

interface IconProps {
  size?: number;
  className?: string;
}

export function FolderIcon({ size = 16, className }: IconProps) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 16 16"
      className={className}
      aria-hidden="true"
    >
      <path
        fill="currentColor"
        d="M2.25 3.5h3.55a1 1 0 0 1 .75.34l.86.97a1 1 0 0 0 .75.34h5.59c.97 0 1.75.78 1.75 1.75v6.35c0 .97-.78 1.75-1.75 1.75H2.25A1.75 1.75 0 0 1 .5 13.25V5.25c0-.97.78-1.75 1.75-1.75Z"
      />
    </svg>
  );
}

export function FolderOpenIcon({ size = 16, className }: IconProps) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 16 16"
      className={className}
      aria-hidden="true"
    >
      <path
        fill="currentColor"
        d="M2.25 3.5h3.55a1 1 0 0 1 .75.34l.86.97a1 1 0 0 0 .75.34h5.59c.97 0 1.75.78 1.75 1.75V8H4.6a1.75 1.75 0 0 0-1.66 1.2l-1.4 4.2A1.74 1.74 0 0 1 .5 12.07V5.25c0-.97.78-1.75 1.75-1.75Zm2.35 5.5h10.4c.6 0 1.04.56.9 1.14l-.85 3.4a1.75 1.75 0 0 1-1.7 1.33H1.6c-.6 0-1.04-.56-.9-1.14l.85-3.4A1.75 1.75 0 0 1 3.25 9h1.35Z"
      />
    </svg>
  );
}

export function DocumentIcon({ size = 16, className }: IconProps) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 16 16"
      className={className}
      aria-hidden="true"
    >
      <path
        fill="currentColor"
        d="M3.5 1.5h5.59c.46 0 .9.18 1.24.51l2.66 2.66c.33.33.51.78.51 1.24v8.59c0 .97-.78 1.75-1.75 1.75H3.5A1.75 1.75 0 0 1 1.75 14.5V3.25c0-.97.78-1.75 1.75-1.75Zm5.5 1.13V5h2.38a.5.5 0 0 0 .35-.85L9.85 2.27a.5.5 0 0 0-.85.35Z"
        opacity="0.9"
      />
      <path
        fill="#ffffff"
        opacity="0.85"
        d="M4.5 8.25h7v.9h-7zM4.5 10.25h7v.9h-7zM4.5 12.25h4.5v.9H4.5z"
      />
    </svg>
  );
}

export function ChevronRightIcon({ size = 10, className }: IconProps) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 10 10"
      className={className}
      aria-hidden="true"
    >
      <path
        fill="none"
        stroke="currentColor"
        strokeWidth="1.6"
        strokeLinecap="round"
        strokeLinejoin="round"
        d="M3.5 2 L7 5 L3.5 8"
      />
    </svg>
  );
}

export function ChevronDownIcon({ size = 10, className }: IconProps) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 10 10"
      className={className}
      aria-hidden="true"
    >
      <path
        fill="none"
        stroke="currentColor"
        strokeWidth="1.6"
        strokeLinecap="round"
        strokeLinejoin="round"
        d="M2 3.5 L5 7 L8 3.5"
      />
    </svg>
  );
}

export function PlusIcon({ size = 14, className }: IconProps) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 14 14"
      className={className}
      aria-hidden="true"
    >
      <path
        fill="none"
        stroke="currentColor"
        strokeWidth="1.5"
        strokeLinecap="round"
        d="M7 2.5 V11.5 M2.5 7 H11.5"
      />
    </svg>
  );
}

export function SidebarIcon({ size = 16, className }: IconProps) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 16 16"
      className={className}
      aria-hidden="true"
    >
      <path
        fill="none"
        stroke="currentColor"
        strokeWidth="1.3"
        d="M2.25 3h11.5c.69 0 1.25.56 1.25 1.25v7.5c0 .69-.56 1.25-1.25 1.25H2.25C1.56 13 1 12.44 1 11.75v-7.5C1 3.56 1.56 3 2.25 3Z"
      />
      <path fill="currentColor" d="M5.5 3v10h-3a1.5 1.5 0 0 1-1.5-1.5v-7A1.5 1.5 0 0 1 2.5 3z" opacity="0.45" />
    </svg>
  );
}
