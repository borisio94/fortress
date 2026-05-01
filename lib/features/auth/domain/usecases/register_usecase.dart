import 'package:equatable/equatable.dart';
import '../entities/user.dart';
import '../repositories/auth_repository.dart';

class RegisterUseCase {
  final AuthRepository repository;
  const RegisterUseCase(this.repository);
  Future<User> call(RegisterParams p) =>
      repository.register(name: p.name, email: p.email, password: p.password, phone: p.phone);
}

class RegisterParams extends Equatable {
  final String name, email, password;
  final String? phone;
  const RegisterParams({required this.name, required this.email, required this.password, this.phone});
  @override List<Object?> get props => [name, email, password, phone];
}
