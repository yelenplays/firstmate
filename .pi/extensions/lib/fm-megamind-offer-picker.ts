// Pi-only presentation for governed Megamind wiki dispositions.
// The coordinator remains the semantic and authorization owner.
import { Key, matchesKey, truncateToWidth, type Component } from "@earendil-works/pi-tui";

export type WikiOfferDisposition =
  | { kind: "offer"; wiki: string }
  | { kind: "different-existing" }
  | { kind: "no-context" }
  | { kind: "unavailable"; choice: "new-wiki" };

export type WikiExistingDisposition =
  | { kind: "existing"; wiki: string }
  | { kind: "show-more" };

type PickerRow<T> = {
  disposition: T;
  label: string;
  description: string;
};

class BasePicker<T> implements Component {
  protected readonly rows: PickerRow<T>[];
  protected selectedIndex: number | null = null;

  public onSelect?: (disposition: T) => void;
  public onCancel?: () => void;

  constructor(rows: PickerRow<T>[]) {
    this.rows = rows;
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
    ];
    this.rows.forEach((row, index) => {
      const marker = this.selectedIndex === index ? "→ " : "  ";
      rendered.push(line(`${marker}${row.label}`), line(`    ${row.description}`));
    });
    rendered.push("", line("↑↓ navigate   enter choose   escape cancel request"));
    return rendered;
  }

  invalidate(): void {}
}

export class WikiOfferDispositionPicker extends BasePicker<WikiOfferDisposition> {
  constructor(offers: string[]) {
    super([
      ...offers.map((wiki) => ({
        disposition: { kind: "offer" as const, wiki },
        label: `${wiki} (offered wiki)`,
        description: "Load only this offer's currently authorized evidence.",
      })),
      {
        disposition: { kind: "different-existing" as const },
        label: "Different existing wiki…",
        description: "Ask Megamind for the current bounded eligible-existing list.",
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
    ]);
  }
}

export class WikiExistingPicker extends BasePicker<WikiExistingDisposition> {
  constructor(wikis: string[], canShowMore = false) {
    super([
      ...wikis.map((wiki) => ({
        disposition: { kind: "existing" as const, wiki },
        label: wiki,
        description: "Choose this name returned by Megamind.",
      })),
      ...(canShowMore
        ? [{
            disposition: { kind: "show-more" as const },
            label: "Show more eligible existing wikis…",
            description: "Ask Megamind for the bounded full list.",
          }]
        : []),
    ]);
  }

  render(width: number): string[] {
    const lines = super.render(width);
    return [
      truncateToWidth("Choose one eligible existing wiki returned by Megamind", Math.max(0, width)),
      ...lines.slice(1),
    ];
  }
}
