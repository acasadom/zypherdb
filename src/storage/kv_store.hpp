#pragma once

// Envoltorio RAII minimo sobre una instancia de RocksDB.
//
// Deliberadamente NO hay jerarquia de clases aqui: un unico tipo concreto,
// movible y no copiable, con errores modelados como valores (std::expected,
// C++23) en vez de excepciones. Es el primer ladrillo de la capa de storage
// sobre la que luego se construira la codificacion de claves para nodos,
// aristas y propiedades.

#include <cstddef>
#include <expected>
#include <filesystem>
#include <iterator>
#include <memory>
#include <optional>
#include <ranges>
#include <string>
#include <string_view>
#include <utility>

namespace acmedb::storage {

enum class KvError {
    OpenFailed,
    WriteFailed,
    ReadFailed,
    DeleteFailed,
    IteratorFailed,
};

namespace detail {
struct IteratorState;
} // namespace detail

// Forward declaration: PrefixIterator is a friend of KvStore.
class KvStore;

// Input iterator over the key/value pairs of a single prefix scan.
//
// Conforms to std::input_iterator: single-pass, so it only models the input
// category. Dereferencing yields a std::pair of string_views whose storage is
// owned by RocksDB and is valid only until the iterator is advanced -- the
// usual contract for database iterators. Copying is not allowed.
class PrefixIterator {
public:
    using iterator_concept  = std::input_iterator_tag;
    using iterator_category = std::input_iterator_tag;
    using value_type        = std::pair<std::string_view, std::string_view>;
    using difference_type   = std::ptrdiff_t;
    using reference         = value_type;

    PrefixIterator() noexcept = default; // end/sentinel-ish state

    [[nodiscard]] reference operator*() const noexcept;
    PrefixIterator& operator++();

    void operator++(int) { ++(*this); }

    friend bool operator==(const PrefixIterator& it, std::default_sentinel_t) noexcept {
        return it.at_end_;
    }
    friend bool operator==(std::default_sentinel_t s, const PrefixIterator& it) noexcept {
        return it == s;
    }

private:
    friend class KvStore;
    friend class PrefixRange;
    friend struct detail::IteratorState;

    // Shared, heap-owned scan state; the owning range keeps it alive. The
    // iterator holds a non-owning pointer, so it must not outlive the range.
    explicit PrefixIterator(detail::IteratorState* state) noexcept;

    // Advance past entries whose key no longer starts with the prefix.
    void seek_to_prefix_start();

    detail::IteratorState* state_ = nullptr;
    bool at_end_ = true;
};

// Owning range of all key/value pairs starting with a given prefix.
//
// Move-only, RAII: owns the underlying RocksDB iterator and releases it on
// destruction. Satisfies std::ranges::input_range so it can be composed with
// the standard views (filter, transform, take, ...), which is exactly the
// shape a Volcano-style executor needs.
class PrefixRange {
public:
    PrefixRange() noexcept;
    PrefixRange(PrefixRange&&) noexcept;
    PrefixRange& operator=(PrefixRange&&) noexcept;
    PrefixRange(const PrefixRange&) = delete;
    PrefixRange& operator=(const PrefixRange&) = delete;
    ~PrefixRange();

    [[nodiscard]] PrefixIterator begin() const;
    [[nodiscard]] std::default_sentinel_t end() const noexcept { return {}; }

    // A scan may carry a RocksDB read error that only surfaces once iteration
    // reaches the failing entry. Check this after a scan completes.
    [[nodiscard]] bool ok() const noexcept;
    [[nodiscard]] KvError error() const noexcept;

private:
    friend class KvStore;
    explicit PrefixRange(std::unique_ptr<detail::IteratorState> state) noexcept;

    std::unique_ptr<detail::IteratorState> state_;
};

class KvStore {
public:
    [[nodiscard]] static std::expected<KvStore, KvError> open(const std::filesystem::path& path);

    KvStore(KvStore&&) noexcept;
    KvStore& operator=(KvStore&&) noexcept;
    KvStore(const KvStore&) = delete;
    KvStore& operator=(const KvStore&) = delete;
    ~KvStore();

    [[nodiscard]] std::expected<void, KvError> put(std::string_view key, std::string_view value);

    // A missing key is a normal outcome, not an error: an empty optional.
    [[nodiscard]] std::expected<std::optional<std::string>, KvError> get(std::string_view key) const;

    [[nodiscard]] std::expected<bool, KvError> exists(std::string_view key) const;

    // Idempotent: deleting a missing key succeeds.
    [[nodiscard]] std::expected<void, KvError> del(std::string_view key);

    // All key/value pairs whose key starts with `prefix`, in key order.
    [[nodiscard]] std::expected<PrefixRange, KvError> scan_prefix(std::string_view prefix) const;

    // Number of keys starting with `prefix`.
    [[nodiscard]] std::expected<std::size_t, KvError> count_prefix(std::string_view prefix) const;

private:
    struct Impl;
    explicit KvStore(std::unique_ptr<Impl> impl);
    std::unique_ptr<Impl> impl_;
};

// Static assertions documenting the ranges conformance we rely on.
static_assert(std::input_iterator<PrefixIterator>);
static_assert(std::ranges::input_range<PrefixRange>);

} // namespace acmedb::storage
