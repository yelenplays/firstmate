// Pi-only presentation for an ambiguous Megamind result.
// The coordinator remains the semantic and authorization owner.
import { Key, matchesKey, truncateToWidth, type Component } from "@earendil-works/pi-tui";

export type WikiOfferDisposition =
  | { kind: "offer"; wiki: string }
  | { kind: "no-context" }
  | { kind: "unavailable"; choice: "different-existing" | "new-wiki" };

type PickerRow = {
  disposition: WikiOfferDisposition;
  label: string;
  description: string;
};

export class WikiOfferDispositionPicker implements Component {
  private readonly rows: PickerRow[];
  private selectedIndex: number | null = null;

  public onSelect?: (disposition: WikiOfferDisposition) => void;
  public onCancel?: () => void;

  constructor(offers: string[]) {
    this.rows = [
      ...offers.map((wiki) => ({
        disposition: { kind: "offer" as const, wiki },
        label: `${wiki} (offered wiki)`,
        description: "Load only this offer's currently authorized evidence.",
      })),
      {
        disposition: { kind: "unavailable" as const, choice: "different-existing" as const },
        label: "Different existing wiki… (not available yet)",
        description: "A safe authorization path for unoffered wikis is not available yet.",
      },
      {
        disposition: { kind: "no-context" as const },
        label: "Continue with no wiki evidence",
        description: "Send the exact request once without loading wiki content.",
      },
      {
        disposition: { kind: "unavailable" as const, choice: "new-wiki" as const },
        label: "Propose a new wiki… (not available yet)",
        description: "The proposal workflow is not available yet; this never creates a wiki.",
      },
    ];
  }

  handleInput(data: string): void {
    if (matchesKey(data, Key.escape) || matchesKey(data, Key.ctrl("c"))) {
      this.onCancel?.();
      return;
    }
    if (matchesKey(data, Key.down)) {
      if (this.selectedIndex === null) this.selectedIndex = 0;
      else this.selectedIndex = Math.min(this.selectedIndex + 1, this.rows.length - 1);
      return;
    }
    if (matchesKey(data, Key.up)) {
      if (this.selectedIndex === null) this.selectedIndex = this.rows.length - 1;
      else this.selectedIndex = Math.max(this.selectedIndex - 1, 0);
      return;
    }
    if (matchesKey(data, Key.enter) && this.selectedIndex !== null) {
      this.onSelect?.(this.rows[this.selectedIndex]!.disposition);
    }
  }

  render(width: number): string[] {
    const line = (text: string) => truncateToWidth(text, Math.max(0, width));
    const rendered = [
      line("Choose wiki evidence for this request"),
      line("Nothing is loaded until you explicitly choose."),
      "",
      line("Offered wikis"),
    ];
    this.rows.forEach((row, index) => {
      if (index > 0 && index === this.rows.length - 3) {
        rendered.push("", line("Other choices"));
      }
      const marker = this.selectedIndex === index ? "→ " : "  ";
      rendered.push(line(`${marker}${row.label}`), line(`    ${row.description}`));
    });
    rendered.push("", line("↑↓ navigate   enter choose   escape cancel request"));
    return rendered;
  }

  invalidate(): void {}
}
