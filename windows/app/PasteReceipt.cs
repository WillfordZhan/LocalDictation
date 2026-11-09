namespace LocalDictation.Windows;

/// <summary>Verify a bounded, exact text change before releasing clipboard
/// ownership to the next segment. The snapshot stays in memory only.</summary>
public sealed class PasteReceipt
{
    public const int MaximumCharacters = 32768;
    private readonly string before;
    private readonly string inserted;
    private readonly int? selectionStart;
    private readonly int? selectionLength;
    public bool CanObserve { get; }

    public PasteReceipt(string before, string inserted, int? selectionStart = null, int? selectionLength = null)
    {
        this.before = Normalize(before); this.inserted = Normalize(inserted);
        this.selectionStart = selectionStart; this.selectionLength = selectionLength;
        bool validSelection = selectionStart == null && selectionLength == null
            || selectionStart is int start && selectionLength is int length && start >= 0 && length >= 0
                && start <= this.before.Length && length <= this.before.Length - start;
        CanObserve = validSelection && this.inserted.Length > 0 && this.before.Length <= MaximumCharacters
            && this.before.Length + this.inserted.Length - (selectionLength ?? 0) <= MaximumCharacters;
    }

    public static string Normalize(string value) => value.Replace("\r\n", "\n").Replace('\r', '\n');

    public bool Matches(string after)
    {
        if (!CanObserve || after.Length > MaximumCharacters) return false;
        after = Normalize(after);
        // An unchanged value cannot prove the queued paste was consumed, even
        // when the user happened to select exactly the same text being pasted.
        if (after == before) return false;
        if (selectionStart is int start && selectionLength is int length)
            return after == before[..start] + inserted + before[(start + length)..];

        // ValuePattern does not expose caret offsets. Accept only one exact
        // replacement of the complete payload with every other character
        // unchanged; a generic value-change event is not an acknowledgement.
        int removed = before.Length + inserted.Length - after.Length;
        if (removed < 0 || removed > before.Length) return false;
        int prefix = 0, suffix = 0;
        while (prefix < Math.Min(before.Length, after.Length) && before[prefix] == after[prefix]) prefix++;
        while (suffix < Math.Min(before.Length, after.Length) && before[^(suffix + 1)] == after[^(suffix + 1)]) suffix++;
        int minimum = Math.Max(0, before.Length - removed - suffix);
        int maximum = Math.Min(prefix, before.Length - removed);
        if (minimum > maximum) return false;
        int occurrence = after.IndexOf(inserted, minimum, StringComparison.Ordinal);
        return occurrence >= minimum && occurrence <= maximum;
    }
}
