import 'package:equatable/equatable.dart';
import '../entities/user.dart';
import '../repositories/auth_repository.dart';

class LoginUseCase {
  final AuthRepository repository;
  const LoginUseCase(this.repository);
  Future<User> call(LoginParams p) =>
      repository.login(email: p.email, password: p.password);
}

class LoginParams extends Equatable {
  final String email, password;
  const LoginParams({required this.email, required this.password});
  @override List<Object> get props => [email, password];
}
