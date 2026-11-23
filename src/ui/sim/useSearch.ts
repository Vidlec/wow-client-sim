// A finder's results as the text is typed: asked for a moment after the typing stops, the answers of older texts
// dropped; asked again when `again` changes (after an accept, the list says "in your log")
import { useEffect, useState } from "react";

const SEARCH_DELAY_MS = 250;

export type Search<T> = { results: T[]; isSearching: boolean; query: string };

export const useSearch = <T>(text: string, find: (query: string) => Promise<T[]>, again: unknown = null): Search<T> => {
  const [results, setResults] = useState<T[]>([]);
  const [isSearching, setSearching] = useState(false);
  const query = text.trim();
  // biome-ignore lint/correctness/useExhaustiveDependencies: `again` only asks once more; `find` is a module's function
  useEffect(() => {
    if (!query) {
      setResults([]);
      setSearching(false);
      return;
    }
    let isCurrent = true;
    setSearching(true);
    const timer = setTimeout(() => {
      find(query)
        .then((found) => {
          if (isCurrent) setResults(found);
        })
        .catch(() => {
          if (isCurrent) setResults([]);
        })
        .finally(() => {
          if (isCurrent) setSearching(false);
        });
    }, SEARCH_DELAY_MS);
    return () => {
      isCurrent = false;
      clearTimeout(timer);
    };
  }, [query, again]);
  return { results, isSearching, query };
};
