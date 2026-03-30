import Foundation

// MARK: - Term Pack Correction

struct TermPackCorrection: Codable, Hashable {
    let original: String
    let replacement: String
    let caseSensitive: Bool

    init(original: String, replacement: String, caseSensitive: Bool = true) {
        self.original = original
        self.replacement = replacement
        self.caseSensitive = caseSensitive
    }
}

// MARK: - Term Pack

struct TermPack: Identifiable {
    let id: String
    let icon: String
    let terms: [String]
    let corrections: [TermPackCorrection]
    let source: Source
    let version: String?
    let author: String?

    let defaultName: String
    let defaultDescription: String
    let localizedNames: [String: String]?
    let localizedDescriptions: [String: String]?

    enum Source: String {
        case builtIn
        case community
    }

    var name: String {
        if source == .community,
           let localizedNames,
           let lang = Locale.current.language.languageCode?.identifier,
           let localized = localizedNames[lang] {
            return localized
        }
        return String(localized: String.LocalizationValue(defaultName))
    }

    var description: String {
        if source == .community,
           let localizedDescriptions,
           let lang = Locale.current.language.languageCode?.identifier,
           let localized = localizedDescriptions[lang] {
            return localized
        }
        return String(localized: String.LocalizationValue(defaultDescription))
    }

    /// Built-in convenience init - same signature as the old memberwise init
    init(id: String, nameKey: String, descriptionKey: String, icon: String, terms: [String]) {
        self.id = id
        self.defaultName = nameKey
        self.defaultDescription = descriptionKey
        self.icon = icon
        self.terms = terms
        self.corrections = []
        self.source = .builtIn
        self.version = nil
        self.author = nil
        self.localizedNames = nil
        self.localizedDescriptions = nil
    }

    /// Community pack init
    init(id: String, name: String, description: String, icon: String,
         terms: [String], corrections: [TermPackCorrection],
         version: String, author: String,
         localizedNames: [String: String]?, localizedDescriptions: [String: String]?) {
        self.id = id
        self.defaultName = name
        self.defaultDescription = description
        self.icon = icon
        self.terms = terms
        self.corrections = corrections
        self.source = .community
        self.version = version
        self.author = author
        self.localizedNames = localizedNames
        self.localizedDescriptions = localizedDescriptions
    }

    /// Total number of entries (terms + corrections)
    var entryCount: Int { terms.count + corrections.count }

    static let builtInIDs: Set<String> = Set(allPacks.map(\.id))

    static let allPacks: [TermPack] = [
        TermPack(
            id: "web-dev",
            nameKey: "Web Development",
            descriptionKey: "termpack.webdev.description",
            icon: "globe",
            terms: [
                "React", "Vue", "Angular", "Next.js", "Nuxt", "Svelte",
                "TypeScript", "JavaScript", "Node.js", "Express",
                "Laravel", "Django", "FastAPI", "Ruby on Rails",
                "PostgreSQL", "MongoDB", "Redis", "GraphQL",
                "Tailwind", "Webpack", "Vite", "npm", "Yarn",
                "REST API", "WebSocket", "OAuth", "JWT",
                "Vercel", "Netlify", "Prisma", "Supabase"
            ]
        ),
        TermPack(
            id: "ios-macos",
            nameKey: "iOS / macOS",
            descriptionKey: "termpack.ios.description",
            icon: "apple.logo",
            terms: [
                "Xcode", "SwiftUI", "UIKit", "AppKit",
                "CocoaPods", "Swift Package Manager", "Carthage",
                "TestFlight", "CloudKit", "Core Data", "SwiftData",
                "Combine", "async await", "Actor",
                "StoreKit", "WidgetKit", "App Intents",
                "Metal", "Core ML", "ARKit", "RealityKit",
                "Instruments", "LLDB", "Simulator",
                "Info.plist", "Entitlements", "Provisioning Profile",
                "App Store Connect", "Xcode Cloud"
            ]
        ),
        TermPack(
            id: "devops",
            nameKey: "DevOps & Cloud",
            descriptionKey: "termpack.devops.description",
            icon: "cloud",
            terms: [
                "Kubernetes", "Docker", "Terraform", "Ansible",
                "AWS", "Azure", "Google Cloud", "Cloudflare",
                "GitHub Actions", "GitLab CI", "Jenkins", "CircleCI",
                "Nginx", "Apache", "Caddy",
                "Prometheus", "Grafana", "Datadog",
                "Helm", "Istio", "ArgoCD",
                "S3", "EC2", "Lambda", "ECS", "EKS",
                "VPC", "CDN", "DNS", "SSL", "TLS"
            ]
        ),
        TermPack(
            id: "data-ai",
            nameKey: "Data & AI",
            descriptionKey: "termpack.ai.description",
            icon: "brain",
            terms: [
                "TensorFlow", "PyTorch", "Keras",
                "Jupyter", "pandas", "NumPy", "scikit-learn",
                "Hugging Face", "LangChain", "OpenAI",
                "GPT", "Claude", "LLM", "RAG",
                "CUDA", "MLOps", "MLflow",
                "Transformer", "BERT", "LoRA",
                "Embeddings", "Vector Database", "Pinecone",
                "Fine-tuning", "Prompt Engineering",
                "Matplotlib", "Seaborn", "Plotly"
            ]
        ),
        TermPack(
            id: "design",
            nameKey: "Design",
            descriptionKey: "termpack.design.description",
            icon: "paintbrush",
            terms: [
                "Figma", "Sketch", "Zeplin", "InVision",
                "Adobe XD", "Photoshop", "Illustrator",
                "Auto Layout", "Responsive Design",
                "Wireframe", "Mockup", "Prototype",
                "Design System", "Style Guide",
                "Typography", "Kerning", "Leading",
                "Bezier", "Vector", "Rasterize",
                "WCAG", "Accessibility", "Color Contrast",
                "Lottie", "Rive"
            ]
        )
    ]
}
