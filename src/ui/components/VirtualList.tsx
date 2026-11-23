// A long list drawn only where it is seen: rows of one height, the ones in view (and a few past them) drawn in a
// scrolled box, the rest standing in as space. The events can be thousands; the page draws a screenful.
import { type ReactNode, useEffect, useRef, useState } from "react";

const OVERSCAN = 8;

type Props<T> = {
  items: readonly T[];
  rowHeight: number;
  /** A key for a row (its item and its place) */
  getKey: (item: T, index: number) => string | number;
  renderRow: (item: T, index: number) => ReactNode;
  className?: string;
  label: string;
};

export const VirtualList = <T,>({ items, rowHeight, getKey, renderRow, className, label }: Props<T>) => {
  const box = useRef<HTMLDivElement>(null);
  const [scrollTop, setScrollTop] = useState(0);
  const [height, setHeight] = useState(400);

  useEffect(() => {
    const element = box.current;
    if (!element) return;
    const observer = new ResizeObserver(() => setHeight(element.clientHeight));
    observer.observe(element);
    return () => observer.disconnect();
  }, []);

  const first = Math.max(0, Math.floor(scrollTop / rowHeight) - OVERSCAN);
  const last = Math.min(items.length, Math.ceil((scrollTop + height) / rowHeight) + OVERSCAN);
  const rows: ReactNode[] = [];
  for (let index = first; index < last; index++) {
    const item = items[index] as T;
    rows.push(
      <li
        key={getKey(item, index)}
        className="absolute inset-x-0"
        style={{ top: index * rowHeight, height: rowHeight }}
      >
        {renderRow(item, index)}
      </li>,
    );
  }

  return (
    <div
      ref={box}
      className={`overflow-y-auto ${className ?? ""}`}
      onScroll={(event) => setScrollTop(event.currentTarget.scrollTop)}
    >
      <ul aria-label={label} className="relative" style={{ height: items.length * rowHeight }}>
        {rows}
      </ul>
    </div>
  );
};
