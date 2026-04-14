import html2canvas from 'html2canvas';

interface ExportImageOptions {
  skillName?: string;
  title?: string;
}

/** Extract a title from markdown content: first # heading, or first non-empty line. */
function extractTitle(content: string): string {
  const headingRe = /^#{1,3}\s+(.+)$/m;
  const headingMatch = headingRe.exec(content);
  if (headingMatch) return headingMatch[1].trim();
  const firstLine = content.split('\n').map((l) => l.trim()).find(Boolean);
  return firstLine || 'AI 分析';
}

/**
 * Export an assistant message's rendered markdown as a long PNG image.
 *
 * Strategy:
 * 1. Clone the .chat-prose node to avoid mutating the visible DOM
 * 2. Place the clone in an offscreen container with light-theme overrides
 * 3. Use html2canvas to render the clone
 * 4. Convert canvas to blob and trigger download
 * 5. Clean up the offscreen container
 */
export async function exportMessageAsImage(
  proseElement: HTMLElement,
  markdownContent: string,
  options?: ExportImageOptions,
): Promise<void> {
  const title = options?.title || extractTitle(markdownContent);
  // Create offscreen container
  const container = document.createElement('div');
  container.style.cssText = `
    position: fixed;
    left: -9999px;
    top: 0;
    z-index: -1;
    background: #ffffff;
    color: #1e293b;
    width: 800px;
    padding: 32px 24px 24px;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", sans-serif;
  `;

  // Add header
  const header = document.createElement('div');
  const now = new Date();
  const timeStr = now.toLocaleString('zh-CN', {
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
  });
  header.innerHTML = `
    <div style="padding-bottom: 16px; border-bottom: 1px solid #e2e8f0; margin-bottom: 16px;">
      <div style="font-size: 18px; font-weight: 700; color: #0f172a;">${title}</div>
      ${options?.skillName ? `<div style="font-size: 13px; color: #64748b; margin-top: 4px;">技能: ${options.skillName}</div>` : ''}
      <div style="font-size: 12px; color: #94a3b8; margin-top: 4px;">${timeStr}</div>
    </div>
  `;
  container.appendChild(header);

  // Clone the prose element and override dark-theme CSS variables
  const clone = proseElement.cloneNode(true) as HTMLElement;
  clone.style.cssText = `
    width: 100%;
    box-sizing: border-box;
    padding: 0;
    margin: 0;
    --chat-prose-fg: #1e293b;
    --chat-prose-link: #0ea5e9;
    --chat-prose-code-fg: #0ea5e9;
    --chat-prose-code-bg: #f1f5f9;
    --chat-prose-pre-bg: #f8fafc;
    --chat-prose-border: #e2e8f0;
    --chat-prose-border-strong: #cbd5e1;
    color: #1e293b;
    font-size: 14px;
    line-height: 1.6;
  `;

  // Remove right padding used for action buttons
  clone.classList.remove('pr-20', 'sm:pr-24');

  container.appendChild(clone);

  // Add footer
  const footer = document.createElement('div');
  footer.innerHTML = `
    <div style="padding-top: 16px; border-top: 1px solid #e2e8f0; margin-top: 16px; font-size: 11px; color: #94a3b8; text-align: center;">
      由问股助手生成
    </div>
  `;
  container.appendChild(footer);

  document.body.appendChild(container);

  try {
    const canvas = await html2canvas(container, {
      backgroundColor: '#ffffff',
      scale: 2,
      useCORS: true,
      logging: false,
    });

    const blob = await new Promise<Blob>((resolve) => {
      canvas.toBlob((b) => resolve(b!));
    });

    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `${title.slice(0, 60)}.png`;
    document.body.appendChild(a);
    a.click();
    a.remove();
    URL.revokeObjectURL(url);
  } finally {
    container.remove();
  }
}
