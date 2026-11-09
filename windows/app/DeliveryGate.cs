namespace LocalDictation.Windows;

/// <summary>A paste is an irreversible external side effect. Even if UI or
/// clipboard code throws after dispatch, a later queue drain cannot retry it.</summary>
public sealed class DeliveryGate
{
    private int attempted;
    public bool TryBegin() => Interlocked.CompareExchange(ref attempted, 1, 0) == 0;
}
