import SwiftUI

/// Consent required before anything that enters the loader on a real block: reading too,
/// because a protected block can wipe itself on entry (docs/flashing.md). Asked once per
/// open sheet; the emulator does not ask.
struct FlashLiabilityConsent: View {
    @Binding var accepted: Bool

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("Программа предоставляется как есть, без каких-либо гарантий. Вход в загрузчик, чтение и запись могут необратимо вывести блок из строя или стереть прошивку. Ответственность за блок, двигатель и последствия несёте вы. Запись проверена только на одном блоке. Сделайте резервную копию и по возможности используйте запасной блок.")
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Понимаю и принимаю риск", isOn: $accepted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Отказ от ответственности", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}
