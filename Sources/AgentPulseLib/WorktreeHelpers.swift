import Foundation

/// ~200 short, distinct animal/nature words for auto-naming worktrees.
public let worktreeWords: [String] = [
    "badger", "falcon", "otter", "raven", "cobra",
    "bison", "crane", "drake", "eagle", "finch",
    "gecko", "heron", "ibis", "jackal", "koala",
    "lemur", "moose", "newt", "ocelot", "panda",
    "quail", "robin", "shark", "tiger", "urchin",
    "viper", "whale", "xerus", "yak", "zebra",
    "albatross", "bear", "camel", "deer", "elk",
    "fox", "gorilla", "hawk", "iguana", "jay",
    "kite", "lynx", "marten", "narwhal", "osprey",
    "parrot", "quetzal", "raptor", "salmon", "toucan",
    "unicorn", "vulture", "wolf", "axolotl", "yeti",
    "zebu", "anchovy", "beetle", "condor", "dolphin",
    "emu", "ferret", "gopher", "hippo", "impala",
    "jaguar", "kiwi", "lobster", "mantis", "numbat",
    "octopus", "puffin", "raccoon", "squid", "turtle",
    "urchin", "vole", "wombat", "xenops", "yapok",
    "zander", "ant", "bat", "crab", "dove",
    "ermine", "frog", "grouse", "hyena", "ibex",
    "jellyfish", "kudu", "lark", "mole", "nutria",
    "owl", "pike", "rabbit", "stork", "toad",
    "umbrellabird", "vicuna", "wren", "ray", "yak",
    "asp", "bobcat", "cicada", "dingo", "egret",
    "flamingo", "gull", "hornet", "inchworm", "junco",
    "katydid", "lamprey", "macaw", "nightjar", "oriole",
    "pelican", "quokka", "rooster", "swift", "thrush",
    "urial", "vervet", "warbler", "xeme", "yellowjacket",
    "aardvark", "beetle", "cheetah", "dugong", "echidna",
    "falcon", "gannet", "hamster", "jacana", "kakapo",
    "loon", "magpie", "nuthatch", "opossum", "penguin",
    "quahog", "rattler", "seal", "tern", "urutu",
    "vanga", "walrus", "xerus", "yellowtail", "zonkey",
    "alpaca", "bunny", "chipmunk", "drongo", "earwig",
    "flounder", "grizzly", "hare", "jackdaw", "kestrel",
    "lizard", "marmot", "nighthawk", "oyster", "piranha",
    "quoll", "remora", "shrike", "tapir", "umbra",
    "vaquita", "weaver", "xantus", "yapok", "zorse",
    "armadillo", "buffalo", "coyote", "darter", "elephant",
    "falcon", "gibbon", "hedgehog", "isopod", "jackrabbit",
    "kingbird", "loris", "meerkat", "nene", "okapi",
    "pronghorn", "quelea", "rosella", "sparrow", "tamarin",
]

/// Pick an unused word by checking existing worktree directory names.
/// Words are shuffled for variety. Returns nil if all exhausted.
public func pickUnusedWord(existingWorktrees: [String], repoName: String) -> String? {
    let usedWords = Set(existingWorktrees.compactMap { name -> String? in
        guard name.hasPrefix("\(repoName)-") else { return nil }
        return String(name.dropFirst(repoName.count + 1))
    })

    let available = worktreeWords.filter { !usedWords.contains($0) }
    return available.randomElement()
}

/// Returns the grouping key for a session directory. Worktree directories
/// (e.g. `/home/dev/myproject-falcon`) map to their parent repo path
/// (e.g. `/home/dev/myproject`), so they group together in the menu.
/// Non-worktree directories return unchanged.
public func groupKey(forDirectory directory: String) -> String {
    let url = URL(fileURLWithPath: directory)
    let dirName = url.lastPathComponent
    guard let lineage = worktreeLineage(directoryName: dirName) else {
        return directory
    }
    return url.deletingLastPathComponent().appendingPathComponent(lineage.repo).path
}

/// If a directory name matches `<repo>-<word>` where word is in worktreeWords,
/// returns `("<word>", "<repo>")`. Otherwise returns nil.
public func worktreeLineage(directoryName: String) -> (word: String, repo: String)? {
    let wordSet = Set(worktreeWords)

    // Try splitting from the right — the last component after the final hyphen
    // that matches a known word is the worktree suffix.
    // This handles hyphenated repo names like "my-project-falcon".
    guard let lastHyphen = directoryName.lastIndex(of: "-") else { return nil }
    let suffix = String(directoryName[directoryName.index(after: lastHyphen)...])
    let prefix = String(directoryName[..<lastHyphen])

    guard !prefix.isEmpty, wordSet.contains(suffix) else { return nil }
    return (word: suffix, repo: prefix)
}
