import '../../../../core/storage/secure_storage.dart';
import '../../domain/entities/user.dart';
import '../../domain/repositories/auth_repository.dart';
import '../datasources/auth_remote_datasource.dart';

class AuthRepositoryImpl implements AuthRepository {
  final AuthRemoteDataSource remoteDataSource;
  AuthRepositoryImpl(this.remoteDataSource);

  @override
  Future<User> login({required String email, required String password}) async {
    final model = await remoteDataSource.login(email: email, password: password);
    return model.toEntity();
  }

  @override
  Future<User> register({required String name, required String email, required String password, String? phone}) async {
    final model = await remoteDataSource.register(name: name, email: email, password: password, phone: phone);
    return model.toEntity();
  }

  @override
  Future<void> logout() => remoteDataSource.logout();

  @override
  Future<User?> getCurrentUser() async {
    final model = await remoteDataSource.getCurrentUser();
    return model?.toEntity();
  }

  @override
  Future<void> forgotPassword(String email) =>
      remoteDataSource.forgotPassword(email);

  @override
  Future<bool> isAuthenticated() => remoteDataSource.isAuthenticated();
}
