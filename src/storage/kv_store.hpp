#pragma once

// Envoltorio RAII minimo sobre una instancia de RocksDB.
//
// Deliberadamente NO hay jerarquia de clases aqui: un unico tipo concreto,
// movible y no copiable, con errores modelados como valores (std::expected,
// C++23) en vez de excepciones. Es el primer ladrillo de la capa de storage
// sobre la que luego se construira la codificacion de claves para nodos,
// aristas y propiedades.

#include <expected>
#include <filesystem>
#include <memory>
#include <string>
#include <string_view>

namespace acmedb::storage {

enum class KvError {
    OpenFailed,
    WriteFailed,
    ReadFailed,
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
    [[nodiscard]] std::expected<std::string, KvError> get(std::string_view key) const;

private:
    struct Impl;
    explicit KvStore(std::unique_ptr<Impl> impl);
    std::unique_ptr<Impl> impl_;
};

} // namespace acmedb::storage
