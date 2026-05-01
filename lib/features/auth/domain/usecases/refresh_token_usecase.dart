import '../repositories/auth_repository.dart';
import '../entities/user.dart';

class RefreshTokenUseCase {
  final AuthRepository repository;
  const RefreshTokenUseCase(this.repository);
  Future<User?> call() => repository.getCurrentUser();
}
