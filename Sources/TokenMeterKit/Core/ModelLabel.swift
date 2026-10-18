import Foundation

/// Models arrive as slugs like `anthropic/claude-sonnet-4.5` or
/// `google/gemini-2.5-flash-preview-09-2025`. These helpers turn them into
/// something legible in a narrow list.
public enum ModelLabel {
    public static func shortName(for slug: String) -> String {
        guard let last = slug.split(separator: "/").last else { return slug }
        return String(last)
    }

    public static func vendor(for slug: String) -> String {
        guard let first = slug.split(separator: "/").first, slug.contains("/") else {
            return "Unknown vendor"
        }
        return prettyCase(String(first))
    }

    static func prettyCase(_ raw: String) -> String {
        switch raw.lowercased() {
        case "openai": "OpenAI"
        case "anthropic": "Anthropic"
        case "google": "Google"
        case "meta-llama": "Meta"
        case "mistralai": "Mistral"
        case "x-ai", "xai": "xAI"
        case "deepseek": "DeepSeek"
        case "qwen": "Qwen"
        case "moonshotai": "Moonshot"
        case "cohere": "Cohere"
        case "amazon": "Amazon"
        case "nvidia": "NVIDIA"
        case "microsoft": "Microsoft"
        case "perplexity": "Perplexity"
        case "openrouter": "OpenRouter"
        default:
            raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }
}
