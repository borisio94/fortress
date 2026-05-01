import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/features/auth/domain/entities/user.dart';
import 'package:fortress/features/auth/domain/repositories/auth_repository.dart';
import 'package:fortress/features/auth/domain/usecases/login_usecase.dart';
import 'package:mocktail/mocktail.dart';

class MockAuthRepository extends Mock implements AuthRepository {}

void main() {
  late LoginUseCase loginUseCase;
  late MockAuthRepository mockRepo;

  setUp(() {
    mockRepo     = MockAuthRepository();
    loginUseCase = LoginUseCase(mockRepo);
  });

  test('should return User when login is successful', () async {
    final user = User(
      id:        '1',
      email:     'test@test.com',
      name:      'Test',
      createdAt: DateTime.now(),
    );

    // login retourne User directement (plus de Either)
    when(() => mockRepo.login(
      email:    any(named: 'email'),
      password: any(named: 'password'),
    )).thenAnswer((_) async => user);

    final result = await loginUseCase(
        const LoginParams(email: 'test@test.com', password: '12345678'));

    expect(result, user);
  });

  test('should throw exception when login fails', () async {
    when(() => mockRepo.login(
      email:    any(named: 'email'),
      password: any(named: 'password'),
    )).thenThrow(Exception('Mot de passe incorrect'));

    expect(
          () => loginUseCase(
          const LoginParams(email: 'test@test.com', password: 'wrong')),
      throwsException,
    );
  });
}